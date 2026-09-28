# Interactive diagrams

Generated with [Archify](https://github.com/tt-a1i/archify) v3.0 (commit `1017b47`) from the typed JSON sources in `src/`. Both files are self-contained, validate at the showcase quality profile, and respect `prefers-color-scheme`.

- `lifecycle.html` - the Intent change lifecycle with lanes for human decision and stops.
- `change-flow.html` - declaration, approval, and verification across the agent, records, reviewer, verifier, and repository checks.

They are embedded in the [visual overview](../index.html). Open either file directly for the full-screen viewer.

Regenerate from this directory (requires Node):

```sh
node /path/to/archify/bin/archify.mjs finalize lifecycle src/lifecycle.json lifecycle.html --quality showcase
node /path/to/archify/bin/archify.mjs finalize sequence src/change-flow.json change-flow.html --quality showcase
```
