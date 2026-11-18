"""Declarative project dependency setup, run by the runner before model work."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


REPORT_PREFIX = 'LAZYAGENTS_ENVIRONMENT='
report = {'status': 'unconfigured', 'manifest': '.lazyagents-deps.json',
          'tools': [], 'caches': [], 'packages': [],
          'go_modules': [], 'npm_projects': [], 'playwright': []}


def inspect_tools(names):
    # Execute only known version commands; arbitrary manifest tool names are
    # checked for presence but never invoked to collect metadata.
    commands = {'git': ['git', '--version'], 'gh': ['gh', '--version'],
                'go': ['go', 'version'], 'node': ['node', '--version'],
                'npm': ['npm', '--version'], 'python3': ['python3', '--version'],
                'rg': ['rg', '--version'], 'make': ['make', '--version'],
                'sqlc': ['sqlc', 'version']}
    for name in sorted(set(names))[:64]:
        path = shutil.which(name) if '/' not in name else None
        tool = {'name': name, 'available': bool(path)}
        if path and name in commands:
            try:
                output = subprocess.check_output(commands[name], stderr=subprocess.STDOUT, timeout=5, text=True)
                tool['version'] = output.splitlines()[0][:200] if output.strip() else 'Version not reported'
            except (OSError, subprocess.SubprocessError):
                tool['version'] = 'Version unavailable'
        report['tools'].append(tool)


def inspect_caches():
    for name, variable in [('Go modules', 'GOMODCACHE'), ('npm downloads', 'npm_config_cache'),
                           ('Playwright browsers', 'PLAYWRIGHT_BROWSERS_PATH'), ('Go build', 'GOCACHE')]:
        location = os.environ.get(variable)
        if not location:
            continue
        directory = Path(location)
        exists = directory.is_dir()
        report['caches'].append({'name': name, 'path': location, 'shared': True,
                                 'exists': exists, 'writable': exists and os.access(directory, os.W_OK)})


def main():
    root = Path.cwd().resolve()
    manifest = root / '.lazyagents-deps.json'
    if not manifest.exists():
        inspect_tools(['git', 'gh', 'go', 'node', 'npm', 'python3', 'rg', 'make', 'sqlc'])
        return
    config = json.loads(manifest.read_text())
    allowed = {'version', 'required_tools', 'go_modules', 'npm_projects', 'playwright'}
    if not isinstance(config, dict) or set(config) - allowed or config.get('version') != 1:
        raise ValueError('expected version 1 dependency manifest with supported fields')

    def values(key):
        result = config.get(key, [])
        if not isinstance(result, list) or any(not isinstance(v, str) or not v for v in result):
            raise ValueError(key + ' must be an array of nonempty strings')
        return result

    def directory(name):
        result = (root / name).resolve()
        if not result.is_relative_to(root) or not result.is_dir():
            raise ValueError('dependency directory must be inside the checkout: ' + name)
        return result

    def run(args, cwd):
        print('→ dependencies: ' + ' '.join(args), flush=True)
        subprocess.run(args, cwd=cwd, check=True)

    for key in ('go_modules', 'npm_projects', 'playwright'):
        report[key] = values(key)
    inspect_tools(values('required_tools'))
    for tool in values('required_tools'):
        if '/' in tool or not shutil.which(tool):
            raise ValueError('missing required tool: ' + tool + '; update the runner image or local tool installation')
    for name in values('go_modules'):
        directory_path = directory(name)
        if not (directory_path / 'go.mod').is_file():
            raise ValueError('missing go.mod in ' + name)
        run(['go', 'mod', 'download'], directory_path)
        try:
            module = json.loads(subprocess.check_output(['go', 'mod', 'edit', '-json'], cwd=directory_path, timeout=10))
            for requirement in module.get('Require', []):
                if not requirement.get('Indirect'):
                    report['packages'].append({'project': name, 'ecosystem': 'Go',
                                               'name': requirement['Path'], 'version': requirement['Version']})
        except (OSError, subprocess.SubprocessError, ValueError, KeyError):
            pass  # Metadata failure must not invalidate successful dependency setup.

    for name in values('npm_projects'):
        directory_path = directory(name)
        lock = directory_path / 'package-lock.json'
        package = directory_path / 'package.json'
        # Include runtime versions: native dependencies may need reinstalling
        # after changing the image or host Node version.
        digest = hashlib.sha256(lock.read_bytes() + package.read_bytes())
        for command in (['node', '--version'], ['npm', '--version']):
            digest.update(subprocess.check_output(command))
        stamp = directory_path / 'node_modules' / '.lazyagents-dependencies'
        expected = digest.hexdigest()
        if not stamp.exists() or stamp.read_text() != expected:
            run(['npm', 'ci', '--include=dev', '--no-audit', '--no-fund'], directory_path)
            stamp.write_text(expected)
        else:
            print('→ dependencies: npm packages already installed in ' + name, flush=True)
        package_info = json.loads(package.read_text())
        locked = json.loads(lock.read_text()).get('packages', {})
        direct = {**package_info.get('dependencies', {}), **package_info.get('devDependencies', {})}
        for dependency in sorted(direct)[:200]:
            version = locked.get('node_modules/' + dependency, {}).get('version', direct[dependency])
            report['packages'].append({'project': name, 'ecosystem': 'npm', 'name': dependency, 'version': version})
    browsers_on_demand = os.environ.get('LAZYAGENTS_PLAYWRIGHT_BROWSERS') == 'on-demand'
    for name in values('playwright'):
        directory_path = directory(name)
        cli = directory_path / 'node_modules' / 'playwright' / 'cli.js'
        if not cli.is_file():
            raise ValueError('Playwright must be a locked npm dependency in ' + name)
        if browsers_on_demand:
            print('→ dependencies: Playwright browsers install on first use in ' + name +
                  ' (npx playwright install chromium)', flush=True)
            continue
        # Playwright skips browser revisions already in the shared cache.
        run(['node', str(cli), 'install', 'chromium'], directory_path)
    report['status'] = 'ready'
    print('→ dependencies ready', flush=True)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        report['status'] = 'failed'
        report['error'] = str(error)[:1000]
        print('Environment setup failed: ' + str(error), file=sys.stderr, flush=True)
        sys.exit(1)
    finally:
        inspect_caches()
        report['packages'] = report['packages'][:200]
        print(REPORT_PREFIX + json.dumps(report, separators=(',', ':')), flush=True)
