# CI workflow pending OAuth scope grant

The CI workflow (`bash -n`, SEED.md section grep, secret hygiene,
brain-template parse) was authored but cannot be pushed via the current
gh CLI auth — the token lacks `workflow` scope.

To add it after authorizing:

```bash
gh auth refresh -s workflow
# Then re-add the workflow file from the initial commit.
git checkout b5b3ad4 -- .github/workflows/ci.yml
git commit -m "ci: enable workflow now that token has workflow scope"
git push origin main
```

The CI source lived at `.github/workflows/ci.yml` and is preserved in
the initial commit `b5b3ad4`. Re-apply from there.
