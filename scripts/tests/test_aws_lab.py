"""Regresiones del coordinador con comandos AWS/Terraform/Docker simulados."""

import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / 'aws_lab.py'
spec = importlib.util.spec_from_file_location('aws_lab', SOURCE)
aws_lab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(aws_lab)
ACCOUNT = '123456789012'
TAG = 'src-0123456789ab'


def role(marker, service):
    name = 'prefix-' + marker + '-suffix'
    return dict(RoleName=name, Arn=f'arn:aws:iam::{ACCOUNT}:role/{name}',
                AssumeRolePolicyDocument={'Statement': [{'Effect': 'Allow',
                    'Principal': {'Service': service}, 'Action': 'sts:AssumeRole'}]})


def platform_state():
    prefix = f'{ACCOUNT}.dkr.ecr.us-east-1.amazonaws.com/netflix-lab-dev'
    return {
        'resources': [{'mode': 'managed', 'type': 'aws_eks_cluster', 'instances': [{}]}],
        'outputs': {
            'cluster_name': {'value': 'netflix-lab-dev'},
            'ecr_repository_urls': {'value': {'backend': prefix + '/backend', 'frontend': prefix + '/frontend'}},
        },
    }


def application_state():
    resources = []
    for service in ('backend', 'frontend'):
        image = f'{ACCOUNT}.dkr.ecr.us-east-1.amazonaws.com/netflix-lab-dev/{service}@sha256:abc'
        resources.append({'mode': 'managed', 'type': 'kubernetes_deployment', 'name': service,
                          'instances': [{'attributes': {'spec': [{'template': [{'spec': [
                              {'container': [{'image': image}]}]}]}]}}]})
    return {'resources': resources, 'outputs': {'namespace': {'value': 'netflix-lab'}, 'image_tag': {'value': TAG}}}


class FakeRunner:
    def __init__(self):
        self.env = {}
        self.calls = []
        self.states = {'platform': {}, 'application': {}}
        self.roles = [role('LabEksClusterRole', 'eks.amazonaws.com'), role('LabEksNodeRole', 'ec2.amazonaws.com')]
        self.fail = None
        self.destroying = {}

    def run(self, *command, capture=False, env=None, stderr_inherit=False):
        words = list(map(str, command))
        self.calls.append((words, env or {}))
        if self.fail and self.fail(words):
            raise aws_lab.LabError('fallo simulado')
        if words[:3] == ['terraform', 'version', '-json']:
            return json.dumps({'terraform_version': '1.17.1'})
        if words[0] == 'aws':
            api = words[3:]
            if api[:2] == ['sts', 'get-caller-identity']:
                return json.dumps({'Account': ACCOUNT})
            if api[:2] == ['iam', 'list-roles']:
                return json.dumps({'Roles': self.roles})
            if api[:2] == ['iam', 'get-role']:
                name = api[api.index('--role-name') + 1]
                return json.dumps({'Role': next(r for r in self.roles if r['RoleName'] == name)})
            if api[:2] == ['s3api', 'list-objects-v2']:
                key = api[api.index('--prefix') + 1]
                stack = key.split('/')[1].split('.')[0]
                return json.dumps({'Contents': [{'Key': key}]} if self.states[stack] else {})
            if api[:2] == ['ecr', 'describe-images']:
                return json.dumps({'imageDetails': [{'imageTags': [TAG]}]})
            if api[:2] in (['s3api', 'head-bucket'], ['eks', 'update-kubeconfig']):
                return ''
            raise AssertionError('AWS no previsto: ' + str(words))
        if words[0] == 'terraform':
            stack = Path(words[1].split('=', 1)[1]).name
            if words[2:4] == ['state', 'pull']:
                return json.dumps(self.states[stack])
            if words[2] == 'plan':
                self.destroying[stack] = '-destroy' in words
            if words[2] == 'apply':
                self.states[stack] = ({'resources': [], 'outputs': {}} if self.destroying[stack]
                                      else platform_state() if stack == 'platform' else application_state())
            return ''
        if words[0] == 'bash':
            return TAG if words[1].endswith('push-images.sh') else ''
        if words[0] in ('docker', 'kubectl', 'python3'):
            return ''
        raise AssertionError('Comando no previsto: ' + str(words))


class CoordinatorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)
        self.environment = patch.dict(os.environ, {}, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.tools = patch.object(aws_lab.shutil, 'which', return_value='/fake/tool')
        self.tools.start()
        self.addCleanup(self.tools.stop)
        printer = patch('builtins.print')
        printer.start()
        self.addCleanup(printer.stop)
        directory = self.root / 'terraform/aws/environments'
        directory.mkdir(parents=True)
        for stack in ('platform', 'application'):
            (directory / f'dev.{stack}.tfvars').write_text(
                'region = "us-east-1"\nenvironment = "dev"\nredis_persistence_enabled = false\n')
        (self.root / 'aws-lab.local.json').write_text(json.dumps({'api_access_cidrs': ['8.8.8.8/32']}))
        self.runner = FakeRunner()

    def lab(self, command='deploy', *flags):
        lab = aws_lab.Lab(aws_lab.arguments([command, *flags]), self.root, self.runner)
        self.addCleanup(lab.close)
        return lab

    def commands(self, name):
        return [words for words, _ in self.runner.calls if words[0] == name]

    def test_config_is_offline_and_state_keys_stable(self):
        lab = self.lab('config')
        lab.execute()
        self.assertEqual(lab.key('platform'), 'dev/platform.tfstate')
        self.assertEqual(lab.key('application'), 'dev/application.tfstate')
        self.assertEqual(self.runner.calls, [])

    def test_region_and_environment_must_match(self):
        path = self.root / 'terraform/aws/environments/dev.application.tfvars'
        path.write_text('region = "us-west-2"\nenvironment = "dev"\n')
        with self.assertRaisesRegex(aws_lab.LabError, 'misma región'):
            self.lab()
        path.write_text('region = "us-east-1"\nenvironment = "prod"\n')
        with self.assertRaisesRegex(aws_lab.LabError, 'environment'):
            self.lab()
        self.assertEqual(self.runner.calls, [])

    def test_custom_json_parameters_keep_same_state(self):
        platform = self.root / 'small.tfvars.json'
        platform.write_text(json.dumps({'region': 'us-east-1', 'environment': 'dev', 'node_count': 2}))
        lab = self.lab('config', '--platform-vars', str(platform))
        self.assertEqual(lab.key('platform'), 'dev/platform.tfstate')
        self.assertEqual(lab.varfiles['platform'], platform)

    def test_nonliteral_identity_is_rejected(self):
        path = self.root / 'terraform/aws/environments/dev.platform.tfvars'
        path.write_text('region = "us-east-1" + "other"\nenvironment = "dev"\n')
        with self.assertRaisesRegex(aws_lab.LabError, 'no literal'):
            self.lab()

    def test_local_config_rejects_credential_fields(self):
        (self.root / 'aws-lab.local.json').write_text(json.dumps({'aws_secret_access_key': 'do-not-store'}))
        with self.assertRaisesRegex(aws_lab.LabError, 'No guardes credenciales'):
            self.lab()

    def test_reuses_legacy_backend_instead_of_new_bucket(self):
        directory = self.root / 'terraform/aws/platform/.terraform'
        directory.mkdir(parents=True)
        (directory / 'terraform.tfstate').write_text(json.dumps({'backend': {'type': 's3', 'config': {
            'bucket': 'previous-team-bucket', 'key': 'dev/platform.tfstate', 'region': 'us-east-1'}}}))
        lab = self.lab('status')
        lab.connect()
        self.assertEqual(lab.bucket, 'previous-team-bucket')

    def test_legacy_workspace_cannot_be_silently_replaced(self):
        directory = self.root / 'terraform/aws/platform/.terraform'
        directory.mkdir(parents=True)
        (directory / 'terraform.tfstate').write_text(json.dumps({'backend': {'type': 's3', 'config': {
            'bucket': 'previous-bucket', 'key': 'dev/platform.tfstate', 'region': 'us-east-1'}}}))
        (directory / 'environment').write_text('other-workspace')
        with self.assertRaisesRegex(aws_lab.LabError, 'workspace'):
            self.lab('status').connect()

    def test_prevents_accidental_bucket_switch(self):
        lab = self.lab('bootstrap', '--bucket', 'first-bucket')
        lab.execute()
        lab.close()
        other = self.lab('status', '--bucket', 'different-bucket')
        with self.assertRaisesRegex(aws_lab.LabError, 'estado paralelo'):
            other.connect()

    def test_context_restores_parameters_from_previous_terminal(self):
        custom = self.root / 'custom.tfvars.json'
        custom.write_text(json.dumps({'region': 'us-east-1', 'environment': 'dev'}))
        lab = self.lab('bootstrap', '--platform-vars', str(custom))
        lab.execute()
        lab.close()
        other = self.lab('status')
        other.connect()
        self.assertEqual(other.varfiles['platform'], custom)

    def test_role_discovery_checks_ambiguity_and_trust(self):
        lab = self.lab()
        lab.connect()
        marker, service = 'LabEksClusterRole', 'eks.amazonaws.com'
        self.assertIn(marker, lab.role('cluster_role_arn', marker, service))
        self.runner.roles.append(role(marker, service))
        with self.assertRaisesRegex(aws_lab.LabError, 'encontrados: 2'):
            lab.role('cluster_role_arn', marker, service)
        self.runner.roles = [role(marker, 'ec2.amazonaws.com')]
        with self.assertRaisesRegex(aws_lab.LabError, 'confianza'):
            lab.role('cluster_role_arn', marker, service)

    def test_role_from_another_account_is_rejected(self):
        lab = self.lab('deploy', '--cluster-role-arn', 'arn:aws:iam::999999999999:role/Other')
        lab.connect()
        with self.assertRaisesRegex(aws_lab.LabError, 'cuenta actual'):
            lab.platform_parameters()

    def test_public_api_cannot_be_opened_to_everyone(self):
        lab = self.lab('deploy', '--api-access-cidrs', '["0.0.0.0/0"]')
        lab.connect()
        with self.assertRaisesRegex(aws_lab.LabError, '0.0.0.0/0'):
            lab.platform_parameters()

    def test_deploy_orders_tests_platform_images_application_and_verification(self):
        lab = self.lab()
        lab.execute()
        words = [c for c, _ in self.runner.calls]
        platform_apply = next(i for i, c in enumerate(words) if c[0] == 'terraform' and 'apply' in c and '/platform' in c[1])
        publish = next(i for i, c in enumerate(words) if c[0] == 'bash' and c[1].endswith('push-images.sh'))
        application_apply = next(i for i, c in enumerate(words) if c[0] == 'terraform' and 'apply' in c and '/application' in c[1])
        tests = next(i for i, c in enumerate(words) if c[0] == 'docker' and 'up' in c)
        bootstrap = next(i for i, c in enumerate(words) if c[0] == 'bash' and c[1].endswith('bootstrap.sh'))
        self.assertLess(tests, bootstrap)
        self.assertLess(platform_apply, publish)
        self.assertLess(publish, application_apply)
        self.assertTrue(any('rollout' in c for c in self.commands('kubectl')))
        self.assertTrue(any('exec' in c for c in self.commands('kubectl')))
        self.assertFalse(any(c[0] == 'aws' and 'create-role' in c for c in words))

    def test_runtime_parameters_are_last_and_outputs_are_consumed(self):
        lab = self.lab()
        lab.execute()
        runtime = json.loads((lab.directory / 'application.runtime.tfvars.json').read_text())
        self.assertEqual(runtime['cluster_name'], 'netflix-lab-dev')
        self.assertEqual(runtime['backend_repository_name'], 'netflix-lab-dev/backend')
        self.assertEqual(runtime['image_tag'], TAG)
        for command in self.commands('terraform'):
            if 'plan' in command:
                varfiles = [value for value in command if value.startswith('-var-file=')]
                self.assertIn('.runtime.tfvars.json', varfiles[-1])
        publisher = next(env for cmd, env in self.runner.calls if cmd[0] == 'bash' and cmd[1].endswith('push-images.sh'))
        self.assertEqual(publisher['ECR_BACKEND_URL'], platform_state()['outputs']['ecr_repository_urls']['value']['backend'])

    def test_application_only_does_not_apply_platform(self):
        self.runner.states['platform'] = platform_state()
        lab = self.lab('deploy', '--stack', 'application')
        lab.execute()
        applies = [c for c in self.commands('terraform') if 'apply' in c]
        self.assertEqual(len(applies), 1)
        self.assertIn('/application', applies[0][1])

    def test_failure_stops_deploy_before_publishing(self):
        self.runner.fail = lambda c: c[0] == 'terraform' and 'plan' in c
        with self.assertRaisesRegex(aws_lab.LabError, 'simulado'):
            self.lab().execute()
        self.assertFalse(any(c[1].endswith('push-images.sh') for c in self.commands('bash')))
        self.assertFalse(any('apply' in c for c in self.commands('terraform')))

    def test_failed_tests_cleanup_and_do_not_bootstrap(self):
        self.runner.fail = lambda c: c[0] == 'docker' and 'up' in c
        with self.assertRaisesRegex(aws_lab.LabError, 'simulado'):
            self.lab().execute()
        self.assertTrue(any('down' in c for c in self.commands('docker')))
        self.assertEqual(self.commands('bash'), [])

    def test_plan_does_not_apply_publish_or_bootstrap(self):
        lab = self.lab('plan', '--stack', 'platform')
        lab.execute()
        self.assertFalse(any('apply' in c for c in self.commands('terraform')))
        self.assertEqual(self.commands('bash'), [])
        self.assertEqual(self.commands('docker'), [])

    def test_destroy_application_before_platform_without_building(self):
        self.runner.states = {'platform': platform_state(), 'application': application_state()}
        lab = self.lab('destroy')
        lab.execute()
        plans = [c for c in self.commands('terraform') if 'plan' in c]
        self.assertIn('/application', plans[0][1])
        self.assertIn('/platform', plans[1][1])
        self.assertTrue(all('-destroy' in c for c in plans))
        self.assertEqual(self.commands('bash'), [])
        self.assertEqual(self.commands('docker'), [])

    def test_platform_destroy_refuses_to_orphan_application(self):
        self.runner.states = {'platform': platform_state(), 'application': application_state()}
        with self.assertRaisesRegex(aws_lab.LabError, 'application todavía'):
            self.lab('destroy', '--stack', 'platform').execute()
        self.assertFalse(any('apply' in c for c in self.commands('terraform')))

    def test_destroy_empty_states_does_not_create_resources(self):
        self.lab('destroy').execute()
        self.assertEqual(self.commands('bash'), [])
        self.assertFalse(any('plan' in c or 'apply' in c for c in self.commands('terraform')))

    def test_status_works_when_only_platform_is_deployed(self):
        self.runner.states['platform'] = platform_state()
        self.lab('status').execute()
        self.assertTrue(any('nodes' in c for c in self.commands('kubectl')))
        self.assertFalse(any('pods,svc,hpa' in c for c in self.commands('kubectl')))

    def test_recovers_legacy_image_tag_from_deployed_digests(self):
        state = application_state()
        del state['outputs']['image_tag']
        self.runner.states['application'] = state
        lab = self.lab('destroy')
        lab.connect()
        self.assertEqual(lab.image_tag(), TAG)
        calls = [c for c in self.commands('aws') if 'describe-images' in c]
        self.assertEqual(len(calls), 2)
        self.assertTrue(all('imageDigest=sha256:abc' in c for c in calls))

    def test_metadata_never_persists_aws_credentials(self):
        os.environ['AWS_SECRET_ACCESS_KEY'] = 'secret-sentinel'
        os.environ['AWS_SESSION_TOKEN'] = 'token-sentinel'
        lab = self.lab()
        lab.execute()
        text = lab.meta_path.read_text()
        self.assertNotIn('secret-sentinel', text)
        self.assertNotIn('token-sentinel', text)
        self.assertNotIn('AWS_SECRET_ACCESS_KEY', text)

    def test_saved_context_does_not_reuse_an_old_ip_for_deploy(self):
        lab = self.lab()
        lab.connect()
        lab.meta['api_access_cidrs'] = ['1.1.1.1/32']
        self.assertEqual(lab.platform_parameters()['api_access_cidrs'], ['8.8.8.8/32'])

    def test_current_ip_is_detected_instead_of_saved_ip(self):
        (self.root / 'aws-lab.local.json').write_text('{}')
        lab = self.lab()
        lab.connect()
        lab.meta['api_access_cidrs'] = ['1.1.1.1/32']
        with patch.object(aws_lab.urllib.request, 'urlopen') as urlopen:
            urlopen.return_value.__enter__.return_value.read.return_value = b'9.9.9.9\n'
            self.assertEqual(lab.platform_parameters()['api_access_cidrs'], ['9.9.9.9/32'])

    def test_failed_application_destroy_does_not_destroy_platform(self):
        self.runner.states = {'platform': platform_state(), 'application': application_state()}
        self.runner.fail = lambda c: c[0] == 'terraform' and 'apply' in c and '/application' in c[1]
        with self.assertRaisesRegex(aws_lab.LabError, 'simulado'):
            self.lab('destroy').execute()
        self.assertFalse(any('apply' in c and '/platform' in c[1] for c in self.commands('terraform')))

    def test_expired_credentials_stop_before_bootstrap(self):
        self.runner.fail = lambda c: c[0] == 'aws' and 'get-caller-identity' in c
        with self.assertRaisesRegex(aws_lab.LabError, 'simulado'):
            self.lab().execute()
        self.assertEqual(self.commands('bash'), [])
        self.assertEqual(self.commands('docker'), [])

    def test_versioned_environment_contracts(self):
        directory = SOURCE.parent.parent / 'terraform/aws/environments'
        for environment in ('dev', 'prod'):
            platform = directory / f'{environment}.platform.tfvars'
            application = directory / f'{environment}.application.tfvars'
            self.assertEqual(aws_lab.literal(platform, 'region'), aws_lab.literal(application, 'region'))
            self.assertEqual(aws_lab.literal(platform, 'environment'), environment)
            self.assertEqual(aws_lab.literal(application, 'environment'), environment)
            self.assertGreaterEqual(aws_lab.literal(application, 'backend_max_replicas'),
                                    aws_lab.literal(application, 'backend_min_replicas'))

    def test_persistence_without_ebs_role_stops_before_bootstrap(self):
        path = self.root / 'terraform/aws/environments/dev.application.tfvars'
        path.write_text('region = "us-east-1"\nenvironment = "dev"\nredis_persistence_enabled = true\n')
        with self.assertRaisesRegex(aws_lab.LabError, 'ebs_csi_role_arn'):
            self.lab().execute()
        self.assertEqual(self.commands('bash'), [])


if __name__ == '__main__':
    unittest.main()
