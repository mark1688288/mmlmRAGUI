# Privacy Policy

[中文](PRIVACY.zh-Hant.md)

mmlmRAGUI (the app name on your Mac is RAGUI) is a local macOS application. The developer is mark1688288. This policy covers the app on the `main` branch. Effective 27 November 2026.

The app keeps its data on your Mac. It has no account, and it does not send your questions, answers, or documents to the developer.

## Data stored on this Mac

**Question history.** When a question is saved, the app stores the question, the answer, the working-directory path, and the time in:

`~/Library/Application Support/mmlmRAGUI/questions.sqlite`

The history list and on-device search use this file. Search vectors stay in memory for that session. They are not written into the file.

**Settings.** The app stores these in its macOS preferences:

- the `rag` executable path
- the working directory
- the interface language
- the sidebar width

They are used only to restore the app the next time it opens.

**Files you choose.** The app reads documents you select and the corpus in the working directory, including `data/corpus.sqlite`, in order to ingest files, answer questions, and preview pages. It does not copy those files into its own store. A saved answer can contain text from those documents, because the answer itself is stored in the history file.

**On-device processing.** Page preview can use Apple's Vision framework to recognize text on a page. History search can use Apple's Natural Language framework. Both run on this Mac for that preview or search. The app does not upload page images or questions for these features.

## What this app does not do

The app has no account, analytics, advertising, or tracking. It does not include a third-party kit that collects data. The app itself does not open a network connection.

## The `rag` command

Asking a question or ingesting a file runs the local `rag` command you set. That command is [mmlmRAG](https://github.com/mark1688288/mmlmRAG), a separate program. By default it uses Ollama on this Mac at `127.0.0.1`. How `rag` handles document text is described by mmlmRAG, not by this policy.

## How long data is kept, and how to delete it

Saved questions stay in `questions.sqlite` until you delete them. In the app, select the questions in History and delete them. That removes those rows.

To delete the whole history, quit RAGUI and move this folder to the Trash:

`~/Library/Application Support/mmlmRAGUI`

The `rag` path, working directory, language, and sidebar width remain in the app's macOS preferences until you change them or remove those preferences. Documents in your working directory are your files. Deleting the app or the history folder does not delete that corpus.

The developer does not hold a copy. There is no remote account to erase.

## Changes

Updates to this policy are posted in this file. The effective date above changes with them.

## Contact

For a question about this policy, open an issue at <https://github.com/mark1688288/mmlmRAGUI/issues>. Do not include document contents or secrets. Report a security vulnerability through [SECURITY.md](SECURITY.md), not in a public issue.
