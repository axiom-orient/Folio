#!/usr/bin/env python3
"""Configure an Xcode-generated hosted test run; never changes app sources/data."""
import argparse
import plistlib
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('input', type=Path)
p.add_argument('output', type=Path)
p.add_argument('--layout', choices=['short','long','single'], default='short')
p.add_argument('--count', type=int, default=512)
p.add_argument('--workers', type=int, default=1)
p.add_argument('--iterations', type=int, default=2)
p.add_argument('--seconds', type=int, default=0)
p.add_argument('--pressure-mib', type=int, default=0)
a = p.parse_args()
products = a.input.resolve().parent
derived = products.parent.parent

def resolve(value):
    if isinstance(value, str):
        return value.replace('__TESTROOT__', str(products)).replace('__DERIVEDDATA__', str(derived))
    if isinstance(value, dict):
        return {k: resolve(v) for k,v in value.items()}
    if isinstance(value, list):
        return [resolve(v) for v in value]
    return value

data = resolve(plistlib.loads(a.input.read_bytes()))
for configuration in data['TestConfigurations']:
    for target in configuration['TestTargets']:
        assert target['IsAppHostedTestBundle']
        host = Path(target['TestHostPath'])
        assert host.is_dir()
        # A generated DSTROOTPath makes Xcode 27.2 select the internal OS
        # root installer on a retail phone. Hosted tests install the signed
        # TestHostPath instead; no OS root is part of this test workload.
        target.pop('DSTROOTPath', None)
        target['OnlyTestIdentifiers'] = ['FolioRuntimeChecks/testSourceBackedStress']
        target['ParallelizationEnabled'] = False
        target['TestTimeoutsEnabled'] = True
        target['DefaultTestExecutionTimeAllowance'] = max(600, a.seconds + 300)
        target['MaximumTestExecutionTimeAllowance'] = max(600, a.seconds + 300)
        env = target.setdefault('EnvironmentVariables', {})
        for key in ['layout','count','workers','iterations','seconds','pressure_mib']:
            env['FOLIO_STRESS_' + key.upper()] = str(getattr(a,key))
a.output.parent.mkdir(parents=True, exist_ok=True)
a.output.write_bytes(plistlib.dumps(data))
