# Security Policy

mmlmRAGUI is a local macOS app for the [mmlmRAG](https://github.com/mark1688288/mmlmRAG) `rag` command. The `main` branch is the supported line. There is no older release line.

## Reporting a vulnerability

Do not open a public issue or pull request for an unfixed vulnerability.

Report it through GitHub private vulnerability reporting:

[https://github.com/mark1688288/mmlmRAGUI/security/advisories/new](https://github.com/mark1688288/mmlmRAGUI/security/advisories/new)

On GitHub that page is **Security → Report a vulnerability**. The report stays off the public issue list. The button is available once this repository is public and private vulnerability reporting is turned on (Settings → Code security → Private vulnerability reporting).

Include:

- The commit or app version you ran, and the macOS version.
- What an attacker gains: code execution, a read or write outside the files named below, or document text leaving the machine.
- Steps to reproduce. A minimal file or corpus entry is welcome. Skip live secrets and anyone else's files.
- Whether you want to be credited, and the name to use.

A flaw in the `rag` command itself belongs in the [mmlmRAG security policy](https://github.com/mark1688288/mmlmRAG/security/policy). Report it here as well when this app's own handling is what makes the flaw reachable.

## Scope

A report is in scope when a document, a path stored in the corpus, a citation, the rag path, the working directory, or a saved question makes this app:

- Start a process other than the `rag` command the user set, the fixed `command -v rag` lookup, or the Python that runs `ragcli` for a local checkout.
- Read or write a file other than the document being previewed, the working directory's corpus, and this app's question history in `~/Library/Application Support/mmlmRAGUI`.
- Send questions, answers, document text, or page images to another machine.
- Open a different file from the path stored for that corpus document.

These are outside this policy:

- A person who already has the operator's macOS account. That account can already change the rag path, read the corpus, and read the question history.
- mmlmRAG, Ollama, model weights, and macOS themselves.
- A scanner finding with no effect on the behavior above.

## Response

This is a single-maintainer project. There is no bug bounty.

- You get an acknowledgement within 7 days.
- A fix, or a written mitigation, is the target within 90 days of the acknowledgement.
- A report that is still open after 30 days gets a status note on the private advisory.
- Please leave the report private until a fix is on `main`, or until 90 days after the acknowledgement, whichever comes first.

A confirmed issue is published as a GitHub Security Advisory when the fix lands. The advisory names you unless you ask to stay anonymous. Good-faith research that follows this policy, on a machine and corpus you are allowed to use, is welcome.
