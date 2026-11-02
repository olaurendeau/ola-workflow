# The prompts follow a writing convention enforced with a whitelist

## Status

accepted

## Date

2026-10-14

## Context

A prompt that offers a human a command which does not exist is found only at the one moment the plugin had to explain itself. A mention and an offer are the same characters, so a check cannot separate them by guessing: five earlier versions, which listed what precedes a path, were each one character short.

## Decision

The suite asks the question the safe way round, so that an offer is a name preceded by one of eight positions (the start of a line, a blank, a tab, three kinds of quote, an opening parenthesis or bracket), and the convention is to describe a wrong spelling and not to write it.

## Consequences

A whitelist errs by missing an offer, a false negative, where a blacklist errs by accusing a sentence. The eight positions are pinned by measuring every printable character, so adding a ninth or dropping one fails. The plugin's namespace spelled wrong is deliberately not checked, since that rule failed on ordinary sentences every time it was narrowed, and the convention applies to the entries of this journal as to every page.

## Evidence

- [Pull request 26](https://github.com/olaurendeau/ola-workflow/pull/26)
- [README, one writing convention, at the commit the journal began](https://github.com/olaurendeau/ola-workflow/blob/936ff0996fbedb5e0d981e91030c9a63efdc00fd/README.md#L455-L494)
