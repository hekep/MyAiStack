# SystemPrompts

One file per genre. The launcher offers them as a numbered menu and passes the
chosen one to the coding agent as its system prompt.

    <name>.txt      plain text, no front matter, no templating

The menu is built by listing this directory, so adding a genre is adding a file.
`coding.txt` is the default, matching the agent harness's own behaviour.

## Why this exists

A model's system prompt should follow from what the model is. Telling MedGemma
it is "an expert coding assistant operating inside pi" measurably degrades it:
asked what it was, it answered `gpt-3.5-turbo`.

## Writing one

Say what the model is looking at and what kind of answer is wanted. Constraints
on *how* to answer are worth more than adjectives about expertise — `health.txt`
forbids the model from doing arithmetic because the numbers are computed before
they reach it, and a 4B model asked to average 8,000 samples will produce a
confident wrong figure.

Note that a Gemma-family template folds the system message into the first user
turn rather than keeping it separate, so it costs prompt tokens either way. Keep
these short.
