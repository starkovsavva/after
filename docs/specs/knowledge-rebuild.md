# Reorganizing selected knowledge notes

This is a local change for the next version. It does not publish an update or
change release metadata. The existing After connection and model selection are
used; the feature does not provision another API key.

## User workflow

1. Open Knowledge base and choose **Reorganize…**.
2. Explicitly select notes in the current library/folder and describe a result:
   projects, overlapping themes, splitting a long note or combining repeated ideas.
3. **Suggest changes** sends only the selected note titles/texts and instruction
   to the displayed provider. Selection starts empty. This creates a proposal,
   never an applied edit.
4. Review existing-note before/after text, new notes with source references,
   named collections and links. Edit or remove proposed changes and revalidate.
5. **Apply** commits the reviewed version atomically. The history offers explicit
   undo while the affected results remain unchanged. Unrelated edits do not
   prevent undo and are never restored from a whole-library backup.

Reorganization creates another arrangement of existing knowledge; a note can
belong to multiple collections. Splitting/merging creates new notes linked to
retained source notes. Explicit original-note edits are shown separately. The
feature does not delete or move source notes, alter recordings or rewrite tasks.
Existing collections remain independently editable through the collections UI.

## Contracts and boundaries

Shared Swift values are in `AfterCore/KnowledgeRebuildModels.swift`. Presentation
and workflow are in `KnowledgeRebuildSheet` and `KnowledgeRebuildController`.
`AppStore.generateKnowledgeRebuild` selects the configured provider, captures the
folder profile and owns cancellation/runtime admission. It invokes a dedicated
short-lived worker; keys live only in its environment, not arguments or drafts.

The `knowledge-rebuild` CLI accepts a server-generated `draftID` on stdin. The
planner reads the trusted context through the repository, rather than accepting
source text from a caller. It returns a `knowledgeRebuild` preview in the existing
worker-event envelope. FFI `kb-rebuild-generate` uses the same planner; it cannot
apply a proposal and is not exposed as an agent MCP mutation tool.

Repository commands:

- `kb-rebuild-prepare`: `{noteIDs, folderID?, instruction}` → frozen context and
  `draftID`, initial `draftRevision: 0`.
- `kb-rebuild-preview`: `{draftID, expectedDraftRevision, proposal}` → validated
  proposal, next draft revision, hash and original values for changed notes.
- `kb-rebuild-apply`: `{draftID, expectedDraftRevision, operationID}` → receipt.
- `kb-rebuild-undo`: `{operationID}` → receipt with `undone: true`.
- `kb-rebuild-history`: bounded list of accessible operations and undo availability.

A proposal has `title`, `summary`, `edits`, `newNotes`, `collections`, and `links`.
References use exactly one source `noteID` or newly proposed `draftKey`. The
repository allocates durable UUIDs. Provider-generated keys never become paths,
commands or durable note IDs. Unknown fields and references are rejected.

## Consistency

Prepare stores current library identity, raw source fingerprints, note revisions
and entity incarnation revisions. Preview, generation and apply recheck live
permissions, folder membership and source versions. Generation also freezes and
rechecks the provider/profile. Draft revision CAS prevents a late model response
from replacing a manually edited review. A changed source requires a new plan.

Apply holds the existing notes lock and one immediate SQLite transaction for
notes, collections, links, workspace events and its receipt. An operation ID is
idempotent and cannot be reused for different content. A draft applies once.

Existing-note edits preserve attachments, tags, unknown fields and unrelated
metadata. As in normal note-save, changed plain text invalidates old rich content
and AI expansion; undo retains their original values. Title-only changes keep
formatting. New notes carry provenance and links to every selected source used.

Undo checks exact affected note/entity versions, new collection/link rows and
references to generated notes. A subsequent edit or new dependency blocks undo.
Hard-deleting a source purges sensitive draft/receipt contents and keeps only the
operation tombstone needed to prevent reuse. Existing SQLite user_version and
legacy writer contracts remain unchanged.

## Limits and current scope

One proposal selects 1–30 ordinary, untrashed notes, at most 60,000 UTF-8 bytes of
source titles/text and a 4,000-byte instruction. At most 30 generated notes,
12 collections, and 60 links including provenance can be applied. The proposal
payload is bounded to 160,000 bytes. Tasks, attachments and recording files are
not sent as source material. Merging across distinct folder scopes is rejected.

The existing local text generator has a 20,000-byte context budget including
system instructions and schema. Oversized local requests fail with a request to
select fewer notes; they are not silently truncated. A proposal does not claim to
cover notes outside its explicit selection. Original-library text is untrusted
data for the model. Meaningful/factual model output still requires human review;
transactional and reference validity are not a semantic quality guarantee.

## Verification

`cargo test --lib knowledge_rebuild` covers transactional preview, source/profile
changes, draft CAS, idempotency, rollback, unknown/rich fields, permissions,
incarnation changes from a released writer and guarded undo.

`scripts/check_knowledge_rebuild.py --engine ENGINE --library LIBRARY` exercises
real CLI/FFI and a loopback-only synthetic LM Studio provider. `--native-app APP`
additionally tests the production Swift generator, cancellation during an in-flight
provider request and successful retry. These tests use no user account/model.

The native Knowledge Base diagnostic exercises actual selection/review controls,
partial rejection and cascading references, manual revalidation, explicit Apply,
history Undo and late-result cancellation on disposable notes. Model semantics
on a user's real notes are deliberately not inferred from deterministic fixtures.
