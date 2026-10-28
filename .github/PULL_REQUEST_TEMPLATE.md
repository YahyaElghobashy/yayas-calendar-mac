<!--
A one-line fix needs only the first section and the checklist. Small pull requests get reviewed fastest;
splitting a large change is worth more than describing it well.
-->

## Summary

What changes, and for a fix, what was wrong.

If this adds or changes a feature, say why it belongs in Yaya’s Calendar, ideally by linking the issue
where that was settled.

## Verification

Where you ran it and **what you could not test**: your Mac, your macOS version, how many Google accounts,
light or dark widgets, which sizes. Every pull request is run on one maintainer’s Mac before it merges,
so the difference between your setup and that one is the useful part.

- [ ] `./build.sh --dev --test` passes
- [ ] `Tools/check-sealed.sh` and `Tools/check-sealed.sh "build/Yaya's Calendar Dev.app"` pass
- [ ] `Tools/check-secrets.sh` and `Tools/check-public.sh --tree .` pass
- [ ] Fixtures, renders and screenshots use only the fictional sample data (no real mail, calendars,
      names or addresses), and committed images went through `Tools/make-icons.sh --strip`
- [ ] A change to a contract, a setting or the network has its line in `docs/DECISIONS.md`

## Anything else

If an issue exists for this, reference it as `Refs #N` (one line per issue).
