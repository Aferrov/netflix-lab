#!/usr/bin/env python3
"""Coordinador local de stacks AWS. Solo biblioteca estándar; nunca almacena claves AWS."""

import argparse
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import urllib.request


class LabError(Exception):
    pass


def literal(path, name, default=None):
    """Lee solo metadatos literales; Terraform sigue interpretando el resto del tfvars.

    region/environment deben ser strings literales. También se inspecciona el booleano
    de persistencia para detectar el requisito EBS antes de crear recursos.
    """
    if path.name.endswith('.json'):
        return read_json(path).get(name, default)
    text = path.read_text()
    matches = list(re.finditer(r'^\s*' + re.escape(name) + r'\s*=\s*', text, re.M))
    if not matches:
        return default
    if len(matches) != 1:
        raise LabError(f'{path}: {name} está repetido')
    try:
        value, end = json.JSONDecoder().raw_decode(text[matches[0].end():])
    except ValueError as error:
        raise LabError(f'{path}: {name} debe ser un literal compatible con JSON') from error
    tail = text[matches[0].end() + end:].split('\n', 1)[0].strip()
    if tail and not tail.startswith(('#', '//')):
        raise LabError(f'{path}: expresión no literal para {name}')
    return value


def read_json(path):
    if not path.exists():
        return {}
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise LabError(f'{path}: se esperaba un objeto JSON')
    return value


class Runner:
    def __init__(self, env):
        self.env = env

    def run(self, *command, capture=False, env=None, stderr_inherit=False):
        print('+ ' + shlex.join(str(x) for x in command), flush=True)
        result = subprocess.run(
            [str(x) for x in command], env={**self.env, **(env or {})},
            text=True, stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.PIPE if capture and not stderr_inherit else None, check=False,
        )
        if result.returncode:
            detail = result.stderr.strip() if capture and not stderr_inherit else 'Revisa el mensaje del comando anterior.'
            raise LabError(f'Falló {command[0]} (código {result.returncode}). {detail}')
        return result.stdout.strip() if capture else ''


class Lab:
    CONFIG_KEYS = {
        'state_bucket', 'cluster_role_arn', 'node_role_arn', 'ebs_csi_role_arn',
        'api_access_cidrs', 'platform_vars', 'application_vars',
    }

    def __init__(self, args, root=None, runner=None):
        self.args = args
        self.root = root or Path(__file__).resolve().parent.parent
        config_path = Path(args.config) if args.config else self.root / 'aws-lab.local.json'
        if args.config and not config_path.is_file():
            raise LabError(f'No existe la configuración: {config_path}')
        self.config = read_json(config_path)
        unknown = set(self.config) - self.CONFIG_KEYS
        if unknown:
            raise LabError(f'Campos no admitidos en configuración local: {sorted(unknown)}. No guardes credenciales aquí.')
        for key, value in self.config.items():
            if value is None:
                continue
            if key == 'api_access_cidrs':
                valid = isinstance(value, list) and all(isinstance(cidr, str) for cidr in value)
            else:
                valid = isinstance(value, str) and bool(value)
            if not valid:
                raise LabError(f'Tipo inválido para {key} en la configuración local.')
        env = dict(os.environ)
        env.update(AWS_PAGER='', TF_IN_AUTOMATION='1', TF_INPUT='0', TF_WORKSPACE='default')
        if args.profile:
            env['AWS_PROFILE'] = args.profile
        self.runner = runner or Runner(env)
        self.meta = {}
        self.states = {}
        self.initialized = set()
        self.lock = None
        self.load_files({})

    def load_files(self, saved):
        self.varfiles = {}
        for stack in ('platform', 'application'):
            key = stack + '_vars'
            filename = getattr(self.args, key) or self.config.get(key) or saved.get(key)
            path = Path(filename) if filename else Path(f'terraform/aws/environments/{self.args.env}.{stack}.tfvars')
            path = path if path.is_absolute() else self.root / path
            if not path.is_file():
                raise LabError(f'No existe el archivo de parámetros: {path}')
            self.varfiles[stack] = path.resolve()
        regions = [literal(p, 'region') for p in self.varfiles.values()]
        environments = [literal(p, 'environment') for p in self.varfiles.values()]
        if any(value != self.args.env for value in environments):
            raise LabError('Los dos tfvars deben declarar environment igual a --env.')
        if regions[0] != regions[1] or regions[0] not in ('us-east-1', 'us-west-2'):
            raise LabError('Los dos tfvars deben declarar la misma región permitida: us-east-1 o us-west-2.')
        self.region = regions[0]
        self.runner.env.update(AWS_REGION=self.region, AWS_DEFAULT_REGION=self.region)

    def aws(self, *args):
        output = self.runner.run('aws', '--region', self.region, *args, '--output', 'json', capture=True)
        return json.loads(output or '{}')

    def setting(self, key):
        environment = 'STATE_BUCKET' if key == 'state_bucket' else 'TF_VAR_' + key
        return (getattr(self.args, key, None) or self.config.get(key)
                or os.environ.get(environment) or self.meta.get(key))

    def legacy_bucket(self):
        buckets = set()
        for stack in ('platform', 'application'):
            path = self.root / 'terraform/aws' / stack / '.terraform/terraform.tfstate'
            backend = read_json(path).get('backend', {})
            config = backend.get('config', {})
            if backend.get('type') == 's3' and config.get('key') == self.key(stack):
                workspace = path.parent / 'environment'
                if workspace.exists() and workspace.read_text().strip() != 'default':
                    raise LabError('La inicialización anterior usa un workspace distinto de default. Revisa ese estado antes de adoptar el backend.')
                if config.get('region') != self.region:
                    raise LabError('El backend anterior usa otra región. Revisa los parámetros antes de continuar.')
                buckets.add(config['bucket'])
        if len(buckets) > 1:
            raise LabError('Los stacks anteriores usan buckets diferentes. Especifica su configuración antes de automatizar.')
        return next(iter(buckets), None)

    def connect(self):
        for tool in ('aws', 'terraform'):
            if not shutil.which(tool):
                raise LabError(f'Falta instalar {tool}.')
        version = json.loads(self.runner.run('terraform', 'version', '-json', capture=True))['terraform_version']
        if tuple(int(n) for n in version.split('-')[0].split('.')[:2]) < (1, 10):
            raise LabError('Se requiere Terraform >= 1.10.')
        self.account = self.aws('sts', 'get-caller-identity')['Account']
        if not re.fullmatch(r'\d{12}', self.account):
            raise LabError('AWS no devolvió un identificador de cuenta válido.')
        self.directory = self.root / '.aws-lab' / self.account / self.args.env
        self.directory.mkdir(parents=True, exist_ok=True)
        self.lock = (self.directory / 'operation.lock').open('a')
        try:
            fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise LabError('Ya hay otra operación local sobre esta cuenta y entorno.') from error
        self.meta_path = self.directory / 'session.json'
        self.meta = read_json(self.meta_path)
        self.load_files(self.meta)
        for key, value in (('account', self.account), ('environment', self.args.env), ('region', self.region)):
            if self.meta.get(key, value) != value:
                raise LabError(f'La sesión guardada no coincide con {key}. No se cambiará de backend automáticamente.')
        self.bucket = self.setting('state_bucket') or self.legacy_bucket() or f'netflix-lab-tfstate-{self.account}-dev'
        if not isinstance(self.bucket, str) or not re.fullmatch(r'[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]', self.bucket):
            raise LabError('Nombre de bucket S3 inválido.')
        if self.meta.get('state_bucket', self.bucket) != self.bucket:
            raise LabError('El bucket difiere del guardado. Migra el estado explícitamente; no se creará un estado paralelo.')
        print(f'Cuenta: {self.account} | entorno: {self.args.env} | región: {self.region} | bucket: {self.bucket}')

    def save(self, **updates):
        self.meta.update(account=self.account, environment=self.args.env, region=self.region,
                         state_bucket=self.bucket, **updates)
        self.meta.update({s + '_vars': str(p) for s, p in self.varfiles.items()})
        temporary = self.meta_path.with_suffix('.tmp')
        temporary.write_text(json.dumps(self.meta, indent=2) + '\n')
        temporary.replace(self.meta_path)

    def key(self, stack):
        return f'{self.args.env}/{stack}.tfstate'

    def backend(self, create=False):
        if create:
            self.runner.run('bash', self.root / 'terraform/aws/bootstrap/bootstrap.sh', self.bucket)
        self.aws('s3api', 'head-bucket', '--bucket', self.bucket, '--expected-bucket-owner', self.account)
        self.save()

    def tf(self, stack, *args, capture=False):
        return self.runner.run(
            'terraform', f'-chdir={self.root / "terraform/aws" / stack}', *args,
            capture=capture, env={'TF_DATA_DIR': str(self.directory / 'terraform-data' / stack)},
        )

    def init(self, stack):
        if stack not in self.initialized:
            self.tf(stack, 'init', '-input=false', f'-backend-config=bucket={self.bucket}',
                    f'-backend-config=key={self.key(stack)}', f'-backend-config=region={self.region}')
            self.initialized.add(stack)

    def state(self, stack):
        if stack not in self.states:
            objects = self.aws('s3api', 'list-objects-v2', '--bucket', self.bucket, '--prefix', self.key(stack))
            if any(item['Key'] == self.key(stack) for item in objects.get('Contents', [])):
                self.init(stack)
                self.states[stack] = json.loads(self.tf(stack, 'state', 'pull', capture=True))
            else:
                self.states[stack] = {}
        return self.states[stack]

    def managed(self, stack):
        return any(r.get('mode') == 'managed' and r.get('instances') for r in self.state(stack).get('resources', []))

    def outputs(self, stack):
        return {k: v['value'] for k, v in self.state(stack).get('outputs', {}).items()}

    def role(self, key, marker, service):
        arn = self.setting(key)
        if arn:
            if not re.fullmatch(r'arn:aws:iam::' + self.account + r':role/.+', arn):
                raise LabError(f'{key} debe pertenecer a la cuenta actual.')
            role = self.aws('iam', 'get-role', '--role-name', arn.rsplit('/', 1)[1])['Role']
        else:
            roles = [r for r in self.aws('iam', 'list-roles')['Roles'] if marker in r['RoleName']]
            if len(roles) != 1:
                raise LabError(f'Se esperó un rol {marker}; encontrados: {len(roles)}. Configura {key} explícitamente.')
            role = roles[0]
        statements = role['AssumeRolePolicyDocument'].get('Statement', [])
        trusted = False
        for statement in statements:
            principal = statement.get('Principal', {})
            services = principal.get('Service', []) if isinstance(principal, dict) else []
            services = [services] if isinstance(services, str) else services
            actions = statement.get('Action', [])
            actions = [actions] if isinstance(actions, str) else actions
            trusted |= (statement.get('Effect') == 'Allow' and service in services and 'sts:AssumeRole' in actions)
        if not trusted:
            raise LabError(f'El rol {role["RoleName"]} no declara confianza en {service}.')
        return role['Arn']

    def platform_parameters(self):
        cluster = self.role('cluster_role_arn', 'LabEksClusterRole', 'eks.amazonaws.com')
        node = self.role('node_role_arn', 'LabEksNodeRole', 'ec2.amazonaws.com')
        if cluster == node:
            raise LabError('El rol del clúster y el de nodos deben ser diferentes.')
        # En despliegue/plan se vuelve a detectar la IP salvo configuración explícita.
        cidrs = (self.args.api_access_cidrs or self.config.get('api_access_cidrs')
                 or os.environ.get('TF_VAR_api_access_cidrs'))
        if self.args.command == 'destroy':
            cidrs = cidrs or self.meta.get('api_access_cidrs')
        if isinstance(cidrs, str):
            cidrs = json.loads(cidrs)
        if not cidrs:
            with urllib.request.urlopen('https://checkip.amazonaws.com', timeout=10) as response:
                address = ipaddress.IPv4Address(response.read().decode().strip())
            cidrs = [str(address) + '/32']
        if not isinstance(cidrs, list) or not cidrs:
            raise LabError('api_access_cidrs debe ser una lista de CIDR IPv4.')
        for cidr in cidrs:
            network = ipaddress.IPv4Network(cidr)
            if network.prefixlen == 0:
                raise LabError('No se permite abrir la API a 0.0.0.0/0.')
        values = dict(cluster_role_arn=cluster, node_role_arn=node, api_access_cidrs=cidrs)
        ebs = self.setting('ebs_csi_role_arn') or literal(self.varfiles['platform'], 'ebs_csi_role_arn')
        if ebs:
            if not re.fullmatch(r'arn:aws:iam::' + self.account + r':role/.+', ebs):
                raise LabError('ebs_csi_role_arn debe ser un rol de la cuenta actual.')
            values['ebs_csi_role_arn'] = ebs
        self.meta.update(values)
        return values

    def require_platform(self):
        outputs = self.outputs('platform')
        if not outputs.get('cluster_name') or not outputs.get('ecr_repository_urls'):
            raise LabError('No hay outputs de platform. Despliega primero --stack platform o --stack all.')
        return outputs

    def image_tag(self):
        tag = self.args.image_tag or os.environ.get('TF_VAR_image_tag') or self.meta.get('image_tag')
        state = self.state('application')
        tag = tag or state.get('outputs', {}).get('image_tag', {}).get('value')
        if not tag:
            # Recuperación del despliegue manual anterior, por sus digests reales.
            matches = []
            for resource in state.get('resources', []):
                if resource.get('type') not in ('kubernetes_deployment', 'kubernetes_deployment_v1'):
                    continue
                if resource.get('name') not in ('backend', 'frontend'):
                    continue
                for instance in resource.get('instances', []):
                    image = instance['attributes']['spec'][0]['template'][0]['spec'][0]['container'][0]['image']
                    if '@sha256:' in image:
                        url, digest = image.split('@', 1)
                        repository = url.split('/', 1)[1]
                        details = self.aws('ecr', 'describe-images', '--repository-name', repository,
                                           '--image-ids', 'imageDigest=' + digest)
                        matches.append(set(details['imageDetails'][0].get('imageTags', [])))
            common = set.intersection(*matches) if len(matches) == 2 else set()
            common.discard('latest')
            if common:
                tag = sorted(common)[0]
        if not tag or tag == 'latest':
            raise LabError('Falta un tag inmutable. Usa --image-tag TAG o despliega primero las imágenes.')
        return tag

    def application_parameters(self, tag):
        outputs = self.require_platform()
        urls = outputs['ecr_repository_urls']
        return dict(cluster_name=outputs['cluster_name'], image_tag=tag,
                    backend_repository_name=urls['backend'].split('/', 1)[1],
                    frontend_repository_name=urls['frontend'].split('/', 1)[1])

    def operation(self, stack, action, values):
        self.save()
        self.init(stack)
        runtime = self.directory / f'{stack}.runtime.tfvars.json'
        runtime.write_text(json.dumps({**values, 'region': self.region, 'environment': self.args.env}, indent=2) + '\n')
        plan = self.directory / f'{stack}.tfplan'
        flags = ['-destroy'] if action == 'destroy' else []
        self.tf(stack, 'plan', '-input=false', '-lock-timeout=60s', *flags,
                f'-var-file={self.varfiles[stack]}', f'-var-file={runtime}', f'-out={plan}')
        if action != 'plan':
            self.tf(stack, 'apply', '-input=false', '-lock-timeout=60s', plan)
            self.states.pop(stack, None)
        plan.unlink(missing_ok=True)

    def local_tests(self):
        if not shutil.which('docker'):
            raise LabError('Docker es necesario para probar y publicar las imágenes.')
        self.runner.run('python3', '-m', 'unittest', 'discover', '-s', self.root / 'scripts/tests', '-v')
        command = ('docker', 'compose', '-p', f'netflix-tests-{self.account}-{self.args.env}',
                   '-f', self.root / 'backend/compose.test.yaml')
        env = {'LOCAL_UID': str(os.getuid()), 'LOCAL_GID': str(os.getgid())}
        try:
            self.runner.run(*command, 'up', '--abort-on-container-exit', '--exit-code-from', 'tests', env=env)
        finally:
            self.runner.run(*command, 'down', '--volumes', env=env)

    def publish(self):
        urls = self.require_platform()['ecr_repository_urls']
        tag = self.runner.run('bash', self.root / 'scripts/push-images.sh', self.args.env, capture=True,
                              env={'ECR_BACKEND_URL': urls['backend'], 'ECR_FRONTEND_URL': urls['frontend']},
                              stderr_inherit=True)
        if not re.fullmatch(r'src-[0-9a-f]{12}', tag):
            raise LabError('push-images.sh no devolvió un tag de contenido válido.')
        self.save(image_tag=tag)
        return tag

    def kubectl(self, *args):
        if not shutil.which('kubectl'):
            raise LabError('Falta instalar kubectl.')
        return self.runner.run('kubectl', '--kubeconfig', self.directory / 'kubeconfig',
                               '--context', self.context, '-n', self.namespace, *args)

    def kubeconfig(self):
        outputs = self.require_platform()
        self.context = f'netflix-lab-{self.account}-{self.args.env}'
        self.namespace = self.outputs('application').get('namespace', 'netflix-lab')
        self.runner.run('aws', '--region', self.region, 'eks', 'update-kubeconfig',
                        '--name', outputs['cluster_name'], '--alias', self.context,
                        '--kubeconfig', self.directory / 'kubeconfig')

    def verify(self):
        self.kubeconfig()
        for name in ('redis', 'backend', 'frontend'):
            self.kubectl('rollout', 'status', 'deployment/' + name, '--timeout=300s')
        # Comprueba el frontend y su proxy API desde un contenedor con Node.js.
        check = ("(async()=>{for(const path of ['/', '/api/info']){"
                 "const r=await fetch('http://frontend'+path,{signal:AbortSignal.timeout(10000)});"
                 "if(r.status!==200)throw Error(path+': HTTP '+r.status);"
                 "if(path==='/api/info'&&!Number.isSafeInteger((await r.json()).visits))"
                 "throw Error('Redis no está disponible');console.log(path+' OK');}})()"
                 ".catch(e=>{console.error(e);process.exitCode=1;});")
        self.kubectl('exec', 'deployment/backend', '--', 'node', '-e', check)
        self.kubectl('get', 'pods,hpa')
        print(f'Despliegue verificado. Dashboard: bash scripts/aws-lab.sh dashboard --env {self.args.env}')

    def execute(self):
        if self.args.command == 'config':
            print(json.dumps(dict(environment=self.args.env, region=self.region,
                                  varfiles={s: str(p) for s, p in self.varfiles.items()},
                                  state_keys={s: self.key(s) for s in self.varfiles}), indent=2))
            return
        self.connect()
        command = self.args.command
        stacks = ('platform', 'application') if self.args.stack == 'all' else (self.args.stack,)
        if command in ('deploy', 'plan'):
            # Antes del bootstrap detecta configuraciones incompatibles con el lab.
            if 'application' in stacks and literal(self.varfiles['application'], 'redis_persistence_enabled', False):
                ebs = self.setting('ebs_csi_role_arn') or literal(self.varfiles['platform'], 'ebs_csi_role_arn')
                if not ebs:
                    raise LabError('Esta configuración activa Redis persistente y requiere ebs_csi_role_arn. Usa dev para el Learner Lab actual.')
            platform_values = self.platform_parameters() if 'platform' in stacks else None
            if command == 'deploy':
                if 'application' in stacks and not shutil.which('kubectl'):
                    raise LabError('Falta instalar kubectl.')
                self.local_tests()
            self.backend(create=command == 'deploy')
            for stack in stacks:
                if stack == 'platform':
                    self.operation(stack, command, platform_values)
                else:
                    tag = self.publish() if command == 'deploy' else self.image_tag()
                    self.operation(stack, command, self.application_parameters(tag))
            if command == 'deploy' and 'application' in stacks:
                self.verify()
        elif command == 'bootstrap':
            self.backend(create=True)
        elif command == 'destroy':
            self.backend()
            if self.args.stack == 'platform' and self.managed('application'):
                raise LabError('application todavía tiene recursos. Destruye application primero o utiliza --stack all.')
            for stack in reversed(stacks):
                if not self.managed(stack):
                    print(f'{stack}: no hay recursos administrados en su estado; se omite.')
                    continue
                values = (self.platform_parameters() if stack == 'platform'
                          else self.application_parameters(self.image_tag()))
                self.operation(stack, 'destroy', values)
            print('Destrucción terminada para los stacks seleccionados. Se conserva el bucket S3 de estado.')
        elif command in ('status', 'dashboard'):
            self.backend()
            if not self.managed('platform'):
                print('No hay plataforma administrada en este estado.')
                return
            has_application = self.managed('application')
            if command == 'dashboard' and not has_application:
                raise LabError('No hay aplicación administrada. Despliega --stack application antes de abrir el dashboard.')
            self.kubeconfig()
            if command == 'dashboard':
                self.close()
                self.lock = None
                self.kubectl('port-forward', 'svc/frontend', '8080:80')
            else:
                if 'platform' in stacks:
                    self.kubectl('get', 'nodes')
                if 'application' in stacks:
                    if has_application:
                        self.kubectl('get', 'pods,svc,hpa')
                    else:
                        print('application: no hay recursos administrados en su estado.')

    def close(self):
        if self.lock:
            self.lock.close()


def arguments(argv=None):
    parser = argparse.ArgumentParser(description='Stacks AWS parametrizados desde tu equipo; usa credenciales de AWS CLI.')
    parser.add_argument('command', choices=['config', 'bootstrap', 'plan', 'deploy', 'status', 'dashboard', 'destroy'])
    parser.add_argument('--env', choices=['dev', 'prod'], default='dev')
    parser.add_argument('--stack', choices=['all', 'platform', 'application'], default='all')
    parser.add_argument('--profile', help='Perfil de AWS CLI (también admite AWS_PROFILE)')
    parser.add_argument('--config', help='JSON local sin credenciales; por defecto aws-lab.local.json')
    parser.add_argument('--bucket', dest='state_bucket', help='Bucket existente o nombre para el bootstrap inicial')
    parser.add_argument('--platform-vars', help='Archivo .tfvars o .tfvars.json completo para platform')
    parser.add_argument('--application-vars', help='Archivo .tfvars o .tfvars.json completo para application')
    parser.add_argument('--cluster-role-arn')
    parser.add_argument('--node-role-arn')
    parser.add_argument('--ebs-csi-role-arn')
    parser.add_argument('--api-access-cidrs', help='Lista JSON; omitir para detectar la IPv4 pública')
    parser.add_argument('--image-tag', help='Tag ya publicado para plan o recuperación de un despliegue manual')
    return parser.parse_args(argv)


def main(argv=None):
    lab = None
    try:
        lab = Lab(arguments(argv))
        lab.execute()
        return 0
    except KeyboardInterrupt:
        print('\nOperación interrumpida. Conserva el estado; vuelve a ejecutar o destruye con credenciales vigentes.', file=sys.stderr)
        return 130
    except (LabError, OSError, ValueError, KeyError) as error:
        print(f'Error: {error}', file=sys.stderr)
        return 1
    finally:
        if lab:
            lab.close()


if __name__ == '__main__':
    sys.exit(main())
