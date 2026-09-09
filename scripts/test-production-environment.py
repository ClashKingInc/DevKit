import copy
import importlib.util
from pathlib import Path
import unittest
import sys
sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location('guard', Path(__file__).with_name('check-production-environment.py'))
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)

class ProtectionTests(unittest.TestCase):
    def test_protection_required(self):
        env = {'can_admins_bypass': False, 'deployment_branch_policy': {'protected_branches': False, 'custom_branch_policies': True}, 'protection_rules': [{'type': 'required_reviewers', 'prevent_self_review': True, 'reviewers': [{'type': 'User', 'reviewer': {'id': 1}}]}]}
        policy = {'branch_policies': [{'name': 'main', 'type': 'branch'}]}
        guard.validate(env, policy)
        for key, bad in [('can_admins_bypass', True), ('protection_rules', []), ('deployment_branch_policy', None)]:
            altered = copy.deepcopy(env); altered[key] = bad
            with self.assertRaises(ValueError): guard.validate(altered, policy)
        altered = copy.deepcopy(env); altered['protection_rules'][0]['prevent_self_review'] = False
        with self.assertRaises(ValueError): guard.validate(altered, policy)
        for policies in [[], [{'name': '*', 'type': 'branch'}], [{'name': 'main', 'type': 'tag'}], policy['branch_policies'] * 2]:
            with self.assertRaises(ValueError): guard.validate(env, {'branch_policies': policies})

if __name__ == '__main__': unittest.main()
