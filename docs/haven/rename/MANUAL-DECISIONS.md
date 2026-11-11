# Remaining manual-review decisions for Haven readiness

Related: #149 / epic #146. Reviewed by **Codex**, 2026-11-11 UTC, under the
owner-approved public-source documentation Implementation Card. These decisions
are subject to human PR review; no operational owner sign-off is implied.

The immutable [inventory](inventory.csv) at public baseline
`c2286bcd266e1924797fc787a677e6f8aa2d94da` contains 125 manual-review records.
[PRESENTATION.md](PRESENTATION.md) and [COMPATIBILITY.md](COMPATIBILITY.md)
already decide 17 distinct records. The table below accounts for the other
**108 records exactly once**. Baseline classifications and `owner_issue`
assignments are historical and remain unchanged. All 108 decisions retain the
current source occurrence; this PR changes none of their source files.

Evidence links pin public `main` at
`93f1c6b3a414b25c94090b10e858c9d6e8f91c05`. Each corresponding baseline line
still exists verbatim there; links use its current line number. This verifies
source continuity, not installed files or external consumers. The baseline
line/column and SHA-256 remain available in inventory.csv, including multiple
occurrences on the same line. Re-review a decision if its consumer changes.

## Decisions and consumer rationale

| Code | Decision / rationale | Consumer evidence and retained boundaries |
| --- | --- | --- |
| R | Preserve runtime compatibility and instructions describing it throughout this epic. | D04–D08/D10: Compose network/project, bootstrap account/path, backup/unit and uninstall allowlists are coupled. Network comments and troubleshooting examples must match those consumers. `scripts/sandbox-firewall.sh`, Compose files, bootstrap, backup and uninstall are source evidence; host agreement stays in E01/E02/E05/E13/E14/E16. No name migration or destructive operation is authorized. |
| I | Preserve derived image identity and technical fixture vocabulary. | D09: sandbox-image publisher, OpenHands Compose image repository/tag, doctor image comparison, installer pair-exact migration and their fixtures use the same derived package. “hybrid” here distinguishes the derived image from stock, including fixture scenario keys; it is not Haven branding. Registry permissions/digests/platforms remain E03/E11. |
| C | Retain active-repository/clone guidance until reviewed cutover alignment. | D01/D08/D14: `cd hybrid-ai`, repository grant examples and OpenHands workspace instructions refer to the current repository or existing clone. #150 must review clone/remotes, documentation and any grant selector against the unchanged repository ID; #151 verifies them. No grant expansion, broad token acceptance or access to another repository follows from preserving an example. |
| H | Preserve historical attribution, migration description or component metadata. | Copyright attribution is not product UI. AGENTS.md describes the old-to-new migration. `.gitignore` and Dockerfile comments identify their existing component; pipe `author` metadata is emitted by build_pipe.py into runpod_pipe.py and is retained together. TLS examples describe existing manually managed configuration, not a request to alter it. The index-design observation remains historical rather than evidence of current external skills. |
| T | Preserve technical “hybrid” terminology. | The index-design document's B2 candidate combines a manifest with a full path list. It is an experimental indexing strategy, not the product name. |
| D | Preserve diagnostic/log/alert text and generated comments. | D04/D10/D11: existing report banners, installer/doctor messages, layout labels, generated backup credential-file comment and TLS subjects remain recognizable to operators. No consumer-independent branding change is needed for rename safety. This decision does not read generated credentials or assert external alert delivery; source text alone is reviewed. |

A preservation decision is completed public-source review, not an external
verification or an approved beyond-epic deferral. C records have an explicit
#150/#151 action; R/I/D records retain existing identities rather than schedule
removal. E01–E20 retain their separate evidence requirements in
[EXTERNAL.md](EXTERNAL.md). D01–D16 refer to [DEPENDENCIES.md](DEPENDENCIES.md).

## Per-occurrence register

Every row's decision is **retain**, qualified by its code above. The reviewer
and review date are stated above; phase ownership below is issue ownership,
not assignment of a named production operator or an access grant.

| Audit ID | Pinned source consumer | Decision | Phase / remaining evidence |
| --- | --- | --- | --- |
| A00048 | [.env.example:310](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/.env.example#L310) | R | #149/E01,E02,E05,E13,E14,E16 as applicable; #150 alignment |
| A00091 | [.github/CICD.md:304](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/.github/CICD.md#L304) | C | #149 preparation; #150 alignment; #151 verification |
| A00103 | [.github/workflows/sandbox-image.yml:104](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/.github/workflows/sandbox-image.yml#L104) | I | #149 / E03,E11; #151 verification |
| A00174 | [.gitignore:2](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/.gitignore#L2) | H | #149 preservation; #151 inventory |
| A00176 | [AGENTS.md:1](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/AGENTS.md#L1) | H | #149 preservation; #151 inventory |
| A00177 | [AGENTS.md:7](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/AGENTS.md#L7) | H | #149 preservation; #151 inventory |
| A00197 | [LICENSE:3](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/LICENSE#L3) | H | #149 preservation; #151 inventory |
| A00364 | [SECURITY.md:380](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/SECURITY.md#L380) | C | #149 preparation; #150 alignment; #151 verification |
| A00383 | [SECURITY.md:549](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/SECURITY.md#L549) | R | #149/E01,E02,E05,E13,E14,E16 as applicable; #150 alignment |
| A00390 | [SECURITY.md:568](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/SECURITY.md#L568) | R | #149/E01,E02,E05,E13,E14,E16 as applicable; #150 alignment |
| A00393 | [SECURITY.md:569](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/SECURITY.md#L569) | R | #149/E01,E02,E05,E13,E14,E16 as applicable; #150 alignment |
| A00890 | [collect-diagnostics.sh:142](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/collect-diagnostics.sh#L142) | D | #149 preservation; #151 compatibility |
| A00891 | [collect-diagnostics.sh:158](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/collect-diagnostics.sh#L158) | D | #149 preservation; #151 compatibility |
| A00896 | [collect-diagnostics.sh:290](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/collect-diagnostics.sh#L290) | D | #149 preservation; #151 compatibility |
| A00917 | [collect-diagnostics.sh:556](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/collect-diagnostics.sh#L556) | R | #149/E01,E02,E05,E13,E14,E16 as applicable; #150 alignment |
| A01119 | [docs/TROUBLESHOOTING.md:43](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/docs/TROUBLESHOOTING.md#L43) | R | #149/E01,E02,E05,E13,E14,E16 as applicable; #150 alignment |
| A01121 | [docs/TROUBLESHOOTING.md:139](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/docs/TROUBLESHOOTING.md#L139) | R | #149/E01,E02,E05,E13,E14,E16 as applicable; #150 alignment |
| A01236 | [docs/TROUBLESHOOTING.md:1104](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/docs/TROUBLESHOOTING.md#L1104) | C | #149 preparation; #150 alignment; #151 verification |
| A01255 | [docs/TROUBLESHOOTING.md:1372](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/docs/TROUBLESHOOTING.md#L1372) | I | #149 / E03,E11; #151 verification |
| A01262 | [docs/TROUBLESHOOTING.md:1421](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/docs/TROUBLESHOOTING.md#L1421) | I | #149 / E03,E11; #151 verification |
| A01264 | [docs/TROUBLESHOOTING.md:1430](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/docs/TROUBLESHOOTING.md#L1430) | I | #149 / E03,E11; #151 verification |
| A01265 | [docs/TROUBLESHOOTING.md:1431](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/docs/TROUBLESHOOTING.md#L1431) | I | #149 / E03,E11; #151 verification |
| A01266 | [docs/TROUBLESHOOTING.md:1533](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/docs/TROUBLESHOOTING.md#L1533) | R | #149/E01,E02,E05,E13,E14,E16 as applicable; #150 alignment |
| A01296 | [docs/TROUBLESHOOTING.md:2108](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/docs/TROUBLESHOOTING.md#L2108) | R | #149/E01,E02,E05,E13,E14,E16 as applicable; #150 alignment |
| A01299 | [docs/TROUBLESHOOTING.md:2122](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/docs/TROUBLESHOOTING.md#L2122) | R | #149/E01,E02,E05,E13,E14,E16 as applicable; #150 alignment |
| A01332 | [docs/TROUBLESHOOTING.md:2341](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/docs/TROUBLESHOOTING.md#L2341) | R | #149/E01,E02,E05,E13,E14,E16 as applicable; #150 alignment |
| A01351 | [docs/TROUBLESHOOTING.md:2489](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/docs/TROUBLESHOOTING.md#L2489) | R | #149/E01,E02,E05,E13,E14,E16 as applicable; #150 alignment |
| A01352 | [docs/TROUBLESHOOTING.md:2508](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/docs/TROUBLESHOOTING.md#L2508) | R | #149/E01,E02,E05,E13,E14,E16 as applicable; #150 alignment |
| A01354 | [docs/agent-context-index-design.md:75](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/docs/agent-context-index-design.md#L75) | T | #149 preservation; #151 inventory |
| A01355 | [docs/agent-context-index-design.md:114](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/docs/agent-context-index-design.md#L114) | T | #149 preservation; #151 inventory |
| A01356 | [docs/agent-context-index-design.md:313](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/docs/agent-context-index-design.md#L313) | C | #149 preparation; #150 alignment; #151 verification |
| A01357 | [docs/agent-context-index-design.md:391](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/docs/agent-context-index-design.md#L391) | H | #149 preservation; #151 inventory |
| A01369 | [docs/tls-acme-design.md:6](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/docs/tls-acme-design.md#L6) | H | #149 preservation; #151 inventory |
| A01384 | [docs/tls-acme-design.md:435](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/docs/tls-acme-design.md#L435) | H | #149 preservation; #151 inventory |
| A01385 | [docs/tls-acme-design.md:437](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/docs/tls-acme-design.md#L437) | H | #149 preservation; #151 inventory |
| A01475 | [docs/tls-acme-design.md:1999](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/docs/tls-acme-design.md#L1999) | H | #149 preservation; #151 inventory |
| A01476 | [docs/tls-acme-design.md:2001](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/docs/tls-acme-design.md#L2001) | H | #149 preservation; #151 inventory |
| A01503 | [docs/tls-renewal-health.md:212](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/docs/tls-renewal-health.md#L212) | R | #149/E01,E02,E05,E13,E14,E16 as applicable; #150 alignment |
| A01517 | [doctor.sh:217](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/doctor.sh#L217) | D | #149 preservation; #151 compatibility |
| A01542 | [doctor.sh:614](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/doctor.sh#L614) | R | #149/E01,E02,E05,E13,E14,E16 as applicable; #150 alignment |
| A01566 | [doctor.sh:1046](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/doctor.sh#L1046) | I | #149 / E03,E11; #151 verification |
| A01631 | [hermes/README.md:318](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/hermes/README.md#L318) | R | #149/E01,E02,E05,E13,E14,E16 as applicable; #150 alignment |
| A01640 | [hermes/README.md:489](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/hermes/README.md#L489) | R | #149/E01,E02,E05,E13,E14,E16 as applicable; #150 alignment |
| A01669 | [hermes/docker-compose.hermes.yml:64](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/hermes/docker-compose.hermes.yml#L64) | R | #149/E01,E02,E05,E13,E14,E16 as applicable; #150 alignment |
| A01685 | [install.sh:197](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/install.sh#L197) | D | #149 preservation; #151 compatibility |
| A01837 | [install.sh:1843](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/install.sh#L1843) | D | #149 preservation; #151 compatibility |
| A01889 | [install.sh:2551](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/install.sh#L2551) | D | #149 preservation; #151 compatibility |
| A01890 | [openhands/AGENTS.md:6](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/openhands/AGENTS.md#L6) | C | #149 preparation; #150 alignment; #151 verification |
| A01891 | [openhands/AGENTS.md:63](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/openhands/AGENTS.md#L63) | C | #149 preparation; #150 alignment; #151 verification |
| A01910 | [openhands/README.md:66](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/openhands/README.md#L66) | R | #149/E01,E02,E05,E13,E14,E16 as applicable; #150 alignment |
| A01914 | [openhands/README.md:80](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/openhands/README.md#L80) | C | #149 preparation; #150 alignment; #151 verification |
| A01915 | [openhands/README.md:84](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/openhands/README.md#L84) | C | #149 preparation; #150 alignment; #151 verification |
| A01917 | [openhands/README.md:87](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/openhands/README.md#L87) | C | #149 preparation; #150 alignment; #151 verification |
| A01934 | [openhands/README.md:248](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/openhands/README.md#L248) | C | #149 preparation; #150 alignment; #151 verification |
| A01942 | [openhands/README.md:365](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/openhands/README.md#L365) | I | #149 / E03,E11; #151 verification |
| A01950 | [openhands/README.md:382](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/openhands/README.md#L382) | I | #149 / E03,E11; #151 verification |
| A01952 | [openhands/README.md:403](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/openhands/README.md#L403) | I | #149 / E03,E11; #151 verification |
| A01955 | [openhands/README.md:417](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/openhands/README.md#L417) | I | #149 / E03,E11; #151 verification |
| A01956 | [openhands/README.md:418](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/openhands/README.md#L418) | I | #149 / E03,E11; #151 verification |
| A01962 | [openhands/agent-server/Dockerfile:3](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/openhands/agent-server/Dockerfile#L3) | H | #149 preservation; #151 inventory |
| A01971 | [openhands/docker-compose.openhands.yml:125](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/openhands/docker-compose.openhands.yml#L125) | R | #149/E01,E02,E05,E13,E14,E16 as applicable; #150 alignment |
| A01978 | [openwebui/build_pipe.py:41](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/openwebui/build_pipe.py#L41) | H | #149 preservation; #151 inventory |
| A01980 | [openwebui/runpod_pipe.py:3](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/openwebui/runpod_pipe.py#L3) | H | #149 preservation; #151 inventory |
| A02523 | [scripts/sandbox-firewall.sh:11](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/scripts/sandbox-firewall.sh#L11) | R | #149/E01,E02,E05,E13,E14,E16 as applicable; #150 alignment |
| A02574 | [scripts/test-agent-image-hybrid-cutover.sh:14](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/scripts/test-agent-image-hybrid-cutover.sh#L14) | I | #149 / E03,E11; #151 verification |
| A02582 | [scripts/test-agent-image-hybrid-cutover.sh:35](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/scripts/test-agent-image-hybrid-cutover.sh#L35) | I | #149 / E03,E11; #151 verification |
| A02583 | [scripts/test-agent-image-hybrid-cutover.sh:36](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/scripts/test-agent-image-hybrid-cutover.sh#L36) | I | #149 / E03,E11; #151 verification |
| A02589 | [scripts/test-agent-image-hybrid-cutover.sh:59](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/scripts/test-agent-image-hybrid-cutover.sh#L59) | I | #149 / E03,E11; #151 verification |
| A02590 | [scripts/test-agent-image-hybrid-cutover.sh:60](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/scripts/test-agent-image-hybrid-cutover.sh#L60) | I | #149 / E03,E11; #151 verification |
| A02636 | [scripts/test-agent-image-hybrid-cutover.sh:318](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/scripts/test-agent-image-hybrid-cutover.sh#L318) | I | #149 / E03,E11; #151 verification |
| A02638 | [scripts/test-agent-image-hybrid-cutover.sh:330](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/scripts/test-agent-image-hybrid-cutover.sh#L330) | I | #149 / E03,E11; #151 verification |
| A02641 | [scripts/test-agent-image-hybrid-cutover.sh:335](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/scripts/test-agent-image-hybrid-cutover.sh#L335) | I | #149 / E03,E11; #151 verification |
| A02642 | [scripts/test-agent-image-hybrid-cutover.sh:337](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/scripts/test-agent-image-hybrid-cutover.sh#L337) | I | #149 / E03,E11; #151 verification |
| A02643 | [scripts/test-agent-image-hybrid-cutover.sh:339](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/scripts/test-agent-image-hybrid-cutover.sh#L339) | I | #149 / E03,E11; #151 verification |
| A02644 | [scripts/test-agent-image-hybrid-cutover.sh:344](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/scripts/test-agent-image-hybrid-cutover.sh#L344) | I | #149 / E03,E11; #151 verification |
| A02648 | [scripts/test-agent-image-hybrid-cutover.sh:359](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/scripts/test-agent-image-hybrid-cutover.sh#L359) | I | #149 / E03,E11; #151 verification |
| A02649 | [scripts/test-agent-image-hybrid-cutover.sh:361](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/scripts/test-agent-image-hybrid-cutover.sh#L361) | I | #149 / E03,E11; #151 verification |
| A02663 | [scripts/test-agent-image-hybrid-cutover.sh:399](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/scripts/test-agent-image-hybrid-cutover.sh#L399) | I | #149 / E03,E11; #151 verification |
| A03375 | [scripts/test-doctor-sandbox-image.sh:8](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/scripts/test-doctor-sandbox-image.sh#L8) | I | #149 / E03,E11; #151 verification |
| A03392 | [scripts/test-doctor-sandbox-image.sh:310](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/scripts/test-doctor-sandbox-image.sh#L310) | I | #149 / E03,E11; #151 verification |
| A03394 | [scripts/test-doctor-sandbox-image.sh:317](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/scripts/test-doctor-sandbox-image.sh#L317) | I | #149 / E03,E11; #151 verification |
| A03396 | [scripts/test-doctor-sandbox-image.sh:322](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/scripts/test-doctor-sandbox-image.sh#L322) | I | #149 / E03,E11; #151 verification |
| A03397 | [scripts/test-doctor-sandbox-image.sh:325](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/scripts/test-doctor-sandbox-image.sh#L325) | I | #149 / E03,E11; #151 verification |
| A03398 | [scripts/test-doctor-sandbox-image.sh:327](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/scripts/test-doctor-sandbox-image.sh#L327) | I | #149 / E03,E11; #151 verification |
| A03399 | [scripts/test-doctor-sandbox-image.sh:327](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/scripts/test-doctor-sandbox-image.sh#L327) | I | #149 / E03,E11; #151 verification |
| A03400 | [scripts/test-doctor-sandbox-image.sh:330](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/scripts/test-doctor-sandbox-image.sh#L330) | I | #149 / E03,E11; #151 verification |
| A03401 | [scripts/test-doctor-sandbox-image.sh:332](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/scripts/test-doctor-sandbox-image.sh#L332) | I | #149 / E03,E11; #151 verification |
| A03402 | [scripts/test-doctor-sandbox-image.sh:336](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/scripts/test-doctor-sandbox-image.sh#L336) | I | #149 / E03,E11; #151 verification |
| A03403 | [scripts/test-doctor-sandbox-image.sh:338](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/scripts/test-doctor-sandbox-image.sh#L338) | I | #149 / E03,E11; #151 verification |
| A03404 | [scripts/test-doctor-sandbox-image.sh:342](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/scripts/test-doctor-sandbox-image.sh#L342) | I | #149 / E03,E11; #151 verification |
| A03405 | [scripts/test-doctor-sandbox-image.sh:344](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/scripts/test-doctor-sandbox-image.sh#L344) | I | #149 / E03,E11; #151 verification |
| A03406 | [scripts/test-doctor-sandbox-image.sh:344](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/scripts/test-doctor-sandbox-image.sh#L344) | I | #149 / E03,E11; #151 verification |
| A03407 | [scripts/test-doctor-sandbox-image.sh:346](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/scripts/test-doctor-sandbox-image.sh#L346) | I | #149 / E03,E11; #151 verification |
| A04285 | [scripts/tls-alert.sh:92](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/scripts/tls-alert.sh#L92) | D | #149 preservation; #151 compatibility |
| A04315 | [scripts/tls-check.sh:445](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/scripts/tls-check.sh#L445) | D | #149 preservation; #151 compatibility |
| A04323 | [scripts/uninstall.sh:5](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/scripts/uninstall.sh#L5) | R | #149/E01,E02,E05,E13,E14,E16 as applicable; #150 alignment |
| A04324 | [scripts/uninstall.sh:16](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/scripts/uninstall.sh#L16) | R | #149/E01,E02,E05,E13,E14,E16 as applicable; #150 alignment |
| A04329 | [scripts/uninstall.sh:23](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/scripts/uninstall.sh#L23) | R | #149/E01,E02,E05,E13,E14,E16 as applicable; #150 alignment |
| A04330 | [scripts/uninstall.sh:24](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/scripts/uninstall.sh#L24) | R | #149/E01,E02,E05,E13,E14,E16 as applicable; #150 alignment |
| A04331 | [scripts/uninstall.sh:25](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/scripts/uninstall.sh#L25) | R | #149/E01,E02,E05,E13,E14,E16 as applicable; #150 alignment |
| A04337 | [scripts/uninstall.sh:83](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/scripts/uninstall.sh#L83) | R | #149/E01,E02,E05,E13,E14,E16 as applicable; #150 alignment |
| A04338 | [scripts/uninstall.sh:83](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/scripts/uninstall.sh#L83) | R | #149/E01,E02,E05,E13,E14,E16 as applicable; #150 alignment |
| A04384 | [scripts/uninstall.sh:296](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/scripts/uninstall.sh#L296) | R | #149/E01,E02,E05,E13,E14,E16 as applicable; #150 alignment |
| A04407 | [scripts/uninstall.sh:426](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/scripts/uninstall.sh#L426) | R | #149/E01,E02,E05,E13,E14,E16 as applicable; #150 alignment |
| A04409 | [scripts/uninstall.sh:571](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/scripts/uninstall.sh#L571) | R | #149/E01,E02,E05,E13,E14,E16 as applicable; #150 alignment |
| A04411 | [scripts/uninstall.sh:723](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/scripts/uninstall.sh#L723) | R | #149/E01,E02,E05,E13,E14,E16 as applicable; #150 alignment |
| A04431 | [status/README.md:310](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/status/README.md#L310) | R | #149/E01,E02,E05,E13,E14,E16 as applicable; #150 alignment |
| A04432 | [status/README.md:310](https://github.com/jimbobsyouruncle/hybrid-ai/blob/93f1c6b3a414b25c94090b10e858c9d6e8f91c05/status/README.md#L310) | R | #149/E01,E02,E05,E13,E14,E16 as applicable; #150 alignment |
