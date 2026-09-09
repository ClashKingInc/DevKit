#!/usr/bin/env python3
"""Fail closed before scheduling private-network work or accessing DB credentials."""
import json
import os
import subprocess


def validate(environment, policies):
    reviewers = [r for r in environment.get('protection_rules', []) if r.get('type') == 'required_reviewers']
    if not reviewers or not reviewers[0].get('reviewers') or not reviewers[0].get('prevent_self_review'):
        raise ValueError('production requires reviewers with self-review disabled')
    if environment.get('can_admins_bypass') is not False:
        raise ValueError('production must disable administrator bypass')
    if environment.get('deployment_branch_policy') != {'protected_branches': False, 'custom_branch_policies': True}:
        raise ValueError('production must use an explicit main-only deployment policy')
    branches = policies.get('branch_policies', [])
    if len(branches) != 1 or branches[0].get('name') != 'main' or branches[0].get('type') != 'branch':
        raise ValueError('production must allow only the main branch, without tags')


def main():
    if os.environ.get('GITHUB_REPOSITORY') != 'ClashKingInc/DevKit' or os.environ.get('GITHUB_REF') != 'refs/heads/main':
        raise ValueError('production migrations run only from ClashKingInc/DevKit main')
    if os.environ.get('GITHUB_EVENT_NAME') != 'workflow_dispatch':
        raise ValueError('production migrations require a manual dispatch')
    if not os.environ.get('GH_TOKEN'):
        raise ValueError('read-only production policy token is required')
    expected = os.environ.get('EXPECTED_SHA', '')
    if len(expected) != 40 or expected != os.environ.get('GITHUB_SHA'):
        raise ValueError('expected commit must equal the dispatched workflow commit')
    def api(path):
        return json.loads(subprocess.check_output(['gh', 'api', f'repos/ClashKingInc/DevKit/{path}'], text=True))
    if api('git/ref/heads/main')['object']['sha'] != expected:
        raise ValueError('main advanced; review and dispatch the new commit')
    validate(api('environments/production'), api('environments/production/deployment-branch-policies'))
    print('Verified production reviewers, no bypass, main-only policy, and exact commit.')


if __name__ == '__main__':
    main()
