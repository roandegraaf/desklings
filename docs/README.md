# Documentation

Start with the [project README](../README.md) for what schermes is and how to run the dev
harness. Everything else is here.

| Document                                | For                                                          |
| --------------------------------------- | ------------------------------------------------------------ |
| [architecture.md](architecture.md)      | Why the system is shaped the way it is                       |
| [development.md](development.md)        | Working on it: workspace, tests, the Docker harness          |
| [deployment.md](deployment.md)          | Running it on Unraid or any Docker host, bare Debian, TLS, backups |
| [configuration.md](configuration.md)    | Every environment variable, and the limits that are not one  |
| [troubleshooting.md](troubleshooting.md) | Symptoms that have happened, and what they turned out to be |

## The rest of the map

The project overview names **eleven** documents. Six of them are the files above, counting the
project README; a seventh, the qcow2 build guide, went away with the VM deploy path. The other
four are sections of `architecture.md` rather than files of their own.

| Subject                             | Where it lives                                                                                   |
| ----------------------------------- | ------------------------------------------------------------------------------------------------ |
| Agent lifecycle                     | [architecture.md § The agent loop](architecture.md#the-agent-loop), and § Restart recovery         |
| Desktop / session archi&shy;tecture | [architecture.md § Display stack](architecture.md#display-stack), and § Agents and their desktops |
| Persistence model                   | [architecture.md § Persistence model](architecture.md#persistence-model)                           |
| Security model                      | [architecture.md § Security model](architecture.md#security-model)                                 |

Those four stayed sections because each is a set of decisions that only makes sense next to the
others. Split out, they would be four short files cross-referencing each other on nearly every
point, with a reader chasing one decision through all of them — the security model is the
privilege model plus the secrets handling plus the single-port rule, and none of the three is
comprehensible alone.

The ones that did get their own file earned it by having a distinct audience and a distinct
moment. You read the deployment guide once when you deploy, the configuration reference when
you need a specific value, and troubleshooting only when something is already wrong.
Architecture is the one you read to understand, and the four subjects above are part of
understanding it.

## How to read architecture.md

Every decision in it is tagged:

- **Requirement** — the product does not work without it.
- **Recommendation** — a considered default a deployment may override.
- **Deferred** — deliberately out of scope, with the trigger that would bring it back.

If you are changing something and a Requirement is in the way, the tag is the signal to find out
why before working around it. Several of them are load-bearing in non-obvious ways, and the
paragraph under each one says how.
