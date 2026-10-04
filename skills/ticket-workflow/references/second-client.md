# A second client surface needs its own pre-delivery check

**Where a project ships more than one client — a mobile app, a CLI, a public API, an embedded widget — code plus passing tests is NOT sufficient.** Work verified entirely against the primary client can be delivered completely broken on the second one, because the two do not share a surface. Treat this as a hard gate whenever a ticket touches the second client.

The four checks, in the order they bite:

1. **The client's own API namespace exposes every action the feature calls.** A second client usually has its own namespace, and a route existing on the primary surface does **not** mean it exists on the other. This is the one that produces a 404 at runtime with a green test suite.
2. **The serializer or sparse-fieldset constants include every field the UI reads.** Second clients are often more aggressively field-limited; a missing field returns **undefined at runtime rather than erroring**, so it looks like a rendering bug and gets debugged in the wrong layer.
3. **The platform's own interaction constraints are exercised, not inherited by assumption.** Anything the primary client gets for free from its runtime — input focus, keyboard occlusion, back-navigation, offline state — has to be handled explicitly on the other.
4. **Request specs against the client's own namespace**, not only the primary one's.

**Find the project's own version of this list** — where a second client exists, the specifics (namespace paths, the field constants, the platform affordance that bites) belong in that project's own docs. This is the obligation; the project supplies the checks.
