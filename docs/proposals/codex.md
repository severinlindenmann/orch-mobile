# orch mobile: independent prototype proposal

Date: 10 October 2026. Status: design proposal, not a protocol amendment.
Target: native Swift/SwiftUI, iPhone, iOS 18 and later.
Deliverable: a complete simulated product in Simulator and TestFlight Demo mode.
Only this proposal is created in this phase; the paths below describe future implementation.

## 1. Position and source precedence

Build a small, trustworthy remote decision surface, organized around workspaces.
The phone should answer “what needs me?” before it explains the machinery behind orch.
It should also make moving a file into a workspace feel as ordinary as sharing a photo.
The prototype must exercise real protocol boundaries, persistence, and extension lifecycles.
It must not imply that a local demonstration proves relay connectivity or APNs delivery.

Read as inputs:

- `orch-core/docs/architecture/orch-v2.md`: §§5–8, §22, D45–D49 and adjacent decisions.
- `orch-relay/docs/protocol-v2.md`: suite 2, sealing, pairing §8, push §9, Drop §10, decisions §13.
- `orch-relay/spikes/s1`: software vectors, Secure Enclave tests, fixture-generation approach.
- `orch-relay/spikes/s2`: PushCore, NSE, shared store, self-test and XcodeGen project.
- `orch-mobile/README.md`, including its proposed Core/app/extension boundaries.
- TIX `workspaces.html`, `index.html`, `files.html`, and needs-you/files phone screenshots.
- The issue scope supplied with this task; no additional issue requirements are assumed.

D45–D49 override stale prose in the architecture and README.
D49 means an unlocked iPhone may sign without a fresh biometric prompt.
It does not remove explicit human confirmation from the app's decision UI.
Protocol v2 determines cryptographic bytes; suite 2 is the only supported suite.
Where native behavior lacks a contract, isolate a proposed adapter and record the gap below.
Do not silently “fix” wire formats to make the demo easier.

Assumptions: one person's device identity, multiple workspaces, one active environment at a time.
The phone is a secondary device, not a recovery-code holder or person-key authority.
Cross-person membership is deliberately gated until architecture and pairing rules agree.
Demo data is synthetic; sharing a real file still creates real local data and must be erasable.
No real relay, HTTP listener, local Python process, or host installation is required to use Demo.

## 2. Product structure and navigation

Use three native root tabs: **Home**, **Needs you**, **Settings**.
Home contains workspace cards followed by Drop; Drop opens a dedicated screen.
Needs you is the cross-workspace actionable queue, with one deduplicated count.
Settings contains device identity, notifications, appearance, Demo controls, and diagnostics.
Each root owns a typed `NavigationStack` so tab changes preserve reading position.
Workspace detail has local tabs: Questions / Tickets / Files / Terminal.
These are a labeled horizontal selector inside the detail, not another bottom tab bar.
At large Dynamic Type, use a compact section menu instead of squeezing four labels.
Terminal opens an explanatory placeholder; it never shows an enabled command field.
Tickets includes Factory summaries, rather than a fifth local tab.

Routes are values: workspace ID, section, entity ID; never a view or decrypted object.
Notification taps and links resolve a route after checking current membership and freshness.
If the workspace was removed, show “This workspace is no longer on this iPhone.”
A deep link opens Home's stack; Back returns to the workspace, then Home.
A question opened from Needs you returns to the same queue position after completion.
Present pairing, Drop compose, and review/sign as sheets with their own navigation state.
Allow only one security-sensitive sheet at once; queue an incoming pairing link for review.
Do not replace an open signing sheet with a notification route.

### 2.1 First launch and Home

First launch offers “Try Demo” as the primary action and “Pair a workspace” as secondary.
In this prototype, real pairing explains that connectivity is not enabled in this build.
Demo entry seeds Laptop and Client VM, a waiting question, tickets, and several Drop files.
A persistent small “Demo · On this iPhone” label appears in the root navigation chrome.
Home's title is “Workspaces”; its trailing plus opens pairing choices.
A Needs you summary above the cards shows a count and the oldest waiting item's age.
Each workspace card has name, one-line description, connection state, and last sync time.
Its lower row shows questions waiting, active tickets, and new files; all counts are scoped.
The card's whole primary area opens its last visited local tab, initially Questions.
A question-count button opens Questions directly and has its own accessibility label.
Client VM says “Hosted by Example Client” with a server icon and an information button.
That information explains that the machine's administrator can read this workspace's data.
Use the signed `client_hosted` flag for the warning; never infer trust from its display name.
The Drop card shows pending local sends and recent items, plus an always-visible Add button.
Pull to refresh reconciles all workspaces concurrently with bounded fan-out.
One unavailable workspace cannot replace the whole Home screen with an error.

### 2.2 Needs you and Questions

Needs you groups by workspace, then oldest unanswered question first.
Filters: All workspaces and an optional workspace picker; avoid a second status taxonomy.
A row shows the action verb, ticket reference, question summary, age, and workspace name.
A stale workspace header says “Last checked 12 min ago”; a count is not asserted as current.
Question detail shows the full prompt, context, source ticket, and structured answer choices.
A “Recommended” annotation is informational and never preselects the answer.
Support a free-text answer or note only when the question's schema allows it.
Selecting an option stages it; “Review answer” opens the sign sheet.
Workspace Questions has Waiting and Answered segments; Answered is a compact history.
Question state is owned by the host, not by a push or local optimistic mutation.
While sending, show “Sending answer…” and prevent a second submission.
After host acceptance, show a checkmark and move the row to Answered.
For `already_answered`, show who answered and when, and discard the unsent staged decision.
For `question_changed`, keep the draft as reference but require rereading and new confirmation.
Offline users may draft answers; they cannot queue an approval for silent future signing.
A lost response is “Checking whether your answer was received,” not “Failed, answer again.”

### 2.3 Tickets, Factory, and Files

Tickets is a searchable list with Active / All filters and native status badges.
Rows show reference, title, stage, assignee label, and a needs-you marker when applicable.
Ticket detail has summary, requirements, activity, questions, and attachments.
Factory epics show child progress and the same ticket detail affordances.
Prototype ticket creation is a labeled simulation of a proposed host operation.
Its compose sheet has title, description, workspace, and Review; no local “created” lie.
Start/move actions use Operate scope and explicit confirmation; unsupported actions explain why.
Do not implement a terminal, arbitrary HTTP bridge, or rich dashboard embedded in a WebView.
Files lists workspace-addressed Drop objects; it is not a remote filesystem browser.
Use search plus All / Images / Text / Other filters and a separate expired-items option.
Rows show filename, sender, note, size, expiry, and transfer state.
File detail shows metadata, recipients, integrity state, download progress, and preview/export.
Preview only after authenticated decryption; use Quick Look for supported safe local types.
Never execute HTML or scripts inside a privileged view; unknown types can be exported explicitly.
Old-epoch objects show “Request access from workspace” for host-assisted DEK rewrap.
Missing historical keys is not reported as corruption or solved by granting all old WKs.
Terminal's page says “Terminal access comes later” and explains the required Type scope.
No simulated shell output that could be mistaken for a working terminal.

### 2.4 Drop and share extension

Drop has Received and Sending segments; Sending includes drafts, queued items, and failures.
The initial scope is immutable files, short text notes, and URLs sent to a member workspace.
Represent notes/URLs as explicit text objects; a pasted URL is never automatically fetched.
Compose starts with destination, then attachment, optional note, and expiry (default seven days).
Default limits: five attachments, 25 MiB total, configurable as prototype policy, not wire law.
Use PhotosPicker and the system document picker; avoid requesting the entire photo library.
Show destination and local-only Demo status immediately above “Send to workspace”.
Receive, preview, export, expiry, retry, and cancel are implemented in the fake host flow.
Claim-once appears in one seeded inbox example; “Claim for Laptop” invokes the host role.
Explain that claim chooses responsibility and does not erase copies already downloaded.
The phone never acquires WXK private material or signs a claim as WSK.
Shared-space membership, document editing/leases, public links, upload links, and voice are later.
Versioned document fixtures may be previewed read-only, with a clear unsupported-edit state.
Transcription stays off and unavailable; no network exception is smuggled into Demo.

“Share to orch” uses a short native compose controller hosted by the share extension.
It reads `NSItemProvider` items, copies them while access is valid, then releases provider URLs.
It lists paired destination names from a protected, minimal App Group index.
Its primary button is “Save to send”; success says “Saved. Open orch to send.”
The extension atomically stages a job and does not promise that an upload has completed.
On app activation the app imports the job, encrypts it, and submits it to FakeHost.
If the app is already active, it also checks the spool on foreground events and a short refresh loop.
The extension cannot call an actor living in the app's process, and cannot force reliable app launch.
This same spool works later with the real client; background upload is a separate milestone.
No workspace: offer “Open orch and pair a workspace,” with Cancel and no retained attachment.
Removed destination: quarantine the job locally and offer a new destination in the app.
Do not silently redirect it to another workspace, even if that workspace is the only one left.

### 2.5 Pairing screens and two distinct comparisons

Entry screen: Scan QR, Paste pairing link, and Demo invitation.
Use explicit paste controls; never inspect the clipboard on launch.
Scanner uses AVFoundation with a framing guide, camera permission rationale, and paste fallback.
Simulator uses paste or a built-in synthetic QR image; physical camera scanning is a device check.
Universal links enter the identical parser and flow; custom `orch://` input is compatibility-only.
Canonical fragment is `v2.ws.offer.secret.wsk_pin.pk_pin`, validated before any connection.
Use protocol `/app/pair`; support `/pair` only as an explicit documented route alias.
A custom-scheme link lacks a relay origin: require an already configured trusted origin or reject.
Never infer an arbitrary endpoint from IDs, follow redirects carrying secrets, or log the fragment.
A review screen shows relay hostname and requested scope; workspace name is unverified initially.
In Demo, the invitation is generated locally and the relay identity reads “Simulated relay”.
The fake transport intercepts it by configuration, never by fallback after a real request fails.

State sequence: parsing → connecting → compare with host → certificate pending → joining → ready.
“Compare with host” displays the six-character SAS in spaced monospaced groups.
Explain: “Compare this code on your workspace computer. Approve there only if it matches.”
Phone actions are Cancel and “Codes don't match”; neither can approve the host's request.
The demo provides a separately labeled “Demo host” panel with Reject as its default action.
Its Approve action becomes available only after explicit “I compared the codes”.
Entering `cert_pending` removes the host SAS immediately, including accessibility announcements.
With a null challenge show “Open orch on Primary Mac,” a waiting indicator, and remaining time.
After validation show a new code labeled “Compare with Primary Mac”.
The Demo primary panel has its own comparison and approval; it is a different actor from FakeHost.
Never display a code for a challenge containing someone else's signing or agreement key.
For that attack show “Pairing stopped: another device's keys were supplied. Reject on your Mac.”
At expiry remove the code immediately; Retry requires a fresh offer, not a resurrected secret.
After approval verify the certificate, member list, card delegation, and signed current WK grant.
Only then persist an active card, derive push keys, and offer notification permission.
An existing valid certificate skips primary approval but still requires the host SAS comparison.
Interrupted pairing resumes its pending request within expiry; secrets live only in protected storage.
Cancel erases local offer material; without a cancellation API explain that the host offer may expire later.
At 60 seconds without a valid answer, show the protocol's used-link warning and a fresh-link action.
A pairing refusal has fixed app-authored copy, never host-supplied HTML or arbitrary instructions.

### 2.6 Review/sign and unlock behavior

Title: “Review answer”; subtitle: workspace name and ticket reference.
Show the complete question, every option relevant to its meaning, the selected answer, and note.
Render long text in a scrollable region without ellipses; retain selectable text and clear boundaries.
Render plain text for approval material; avoid Markdown links, hidden markup, and bidi surprises.
Show an expandable “Signed details” block with workspace ID, question ID, and full content hash.
The summary derives from the same immutable decision value that builds the canonical signing bytes.
The decision signature binds workspace, question, content hash, decision ID, and answer per §13.
No app-only prose is claimed to be cryptographically signed if it is absent from that contract.
Primary button: “Sign and send answer”; secondary: Cancel.
Footnote: “This unlocked iPhone signs with its device key.”
D49 means no automatic Face ID prompt per tap; never advertise fresh biometric proof.
If protected data is unavailable, replace the action with “Unlock iPhone to continue”.
On returning unlocked, refetch state and require another explicit tap; do not auto-sign.
Passcode missing: explain that device signing requires a passcode, with a Settings instruction.
A content change while the sheet is open invalidates the staged value and disables signing.
A lock/background transition clears sensitive presentation and any in-memory approval intent.
An authentication cancellation leaves the draft intact and creates no decision envelope.
The same sheet pattern applies to removal and supported Operate actions with action-specific text.

### 2.7 Settings, logout, and revocation

Global Settings: device label, person fingerprint, notification permission, appearance, Demo, About.
Workspace settings: identity/pins, scopes, host status, member devices, storage usage, leave action.
Scopes appear as readable permissions; unavailable controls include an explanation, not only gray text.
“Remove from this iPhone” is workspace logout: local wipe plus membership/push deregistration.
Confirmation names the workspace and number of unsent files; destructive action is red.
It does not delete the shared device identity while other workspaces or cleanup jobs need it.
Successful online logout removes the card and confirms “Removed from this iPhone”.
Offline logout wipes immediately and separately reports “Server removal pending”.
Retain only a minimal authenticated cleanup job, never the workspace's plaintext or WK.
Never claim server revocation or remote erasure while offline; retry when connectivity returns.
If final identity deletion prevents authentication, require pairing/primary-device cleanup instead.
A member with Operate may “Remove this device from workspace”; host rotates the epoch.
Global lost-device revocation requires PK: this phone explains “Revoke on your primary device”.
Demo can open a labeled simulated primary panel to issue a real signed fake revocation.
Receiving verified revocation or membership removal locks access, wipes that workspace, and explains why.
Global revocation wipes all affected workspaces and disables the device identity.
State plainly that revocation protects future content; it cannot erase already downloaded copies.

### 2.8 Empty, failure, and notification states

| Situation | Presentation and next action |
|---|---|
| No workspaces | “Your workspaces will appear here”; Try Demo / Pair |
| No questions | “Nothing needs you”; last checked time, no invented success metric |
| Empty Files or Drop | Short explanation plus Add file |
| Host offline | Cached content, last sync time, Retry; decisions remain drafts |
| Relay unavailable | Per-workspace connection banner; preserve navigation and reading |
| Permission denied | Explain limited capability; explicit Open Settings action |
| Unsupported scope | Required permission and where to request it |
| Invalid signature/pin | Block that content; security-specific error and re-pair guidance |
| Missing epoch | “Waiting for workspace keys”; refresh grant, no trial decryption |
| Storage full | Retain recoverable draft; show required space and retry |
| Key missing after restore | Re-pair; never silently generate a replacement under the old ID |
| Unknown feature/version | Read-only explanation; never crash or invent default permissions |

Ask for notifications after the first successful join, with a preview of their usefulness.
Keep app badge as the last reconciled unanswered count, not the count of received APNs packets.
No approve/reject actions on the lock-screen notification: tapping opens review after unlock.
On foreground push, refresh the visible question and use a modest banner only if useful.
For closed questions, replace the older delivered item with “Answered on …” when verified.
No celebratory sound for a closure; let the initial question use the user's normal alert policy.
On notification tap, reverify its sealed data and fetch authoritative state before enabling action.
Default preview preference follows system settings; offer an additional “Hide question text” option.
Before first unlock, unknown keys, invalid payloads, or extension timeout yield generic app-authored text.
A rejected cryptographic payload must never become trusted navigation or display its label.

## 3. Visual language: quiet field notebook

Use warm paper surfaces, dark ink, teal actions, and amber attention marks.
The distinguishing motif is a small inset vertical “attention rail” on waiting-question cards.
Avoid terminal green, neon dashboards, fake glass, gradients, or excessive status chips.
Take TIX's direct question/options hierarchy and generous file rows, not its fonts or navigation code.
Use native bars, sheets, menus, context actions, toggles, search, and system keyboard behavior.
Keep one visually dominant action per screen; a destructive action never borrows the teal accent.

### 3.1 Proposed `OrchTokens.swift` values

| Semantic color | Light hex | Dark hex | Use |
|---|---|---|---|
| canvas | F6F4EF | 111715 | Root background |
| surface | FFFFFC | 1B2420 | Cards and sheets |
| surfaceRaised | EDEFE9 | 25302A | Insets and secondary groups |
| ink | 192720 | EDF3EE | Primary text |
| inkSecondary | 536258 | AABBAF | Supporting text |
| separator | D4DBD2 | 3C4C41 | Decorative borders |
| accent | 006A55 | 78D8B4 | Links, selected controls |
| accentFill | 006A55 | 78D8B4 | Primary button background |
| onAccent | FFFFFF | 10281E | Primary button label |
| attention | 805000 | F0C574 | Waiting text/icon |
| attentionSurface | FFF0CE | 3C3018 | Waiting card inset |
| destructive | B32632 | FFABB0 | Remove, reject, errors |
| success | 27633C | 94D8A4 | Accepted confirmation |
| demo | 655080 | CDB5EB | Persistent simulated-state label |

Implement as semantic dynamic `Color` values via trait-aware UIKit color resolution.
Use system secondary labels and fills for native controls instead of recoloring every UIKit surface.
Check token pairs at normal text contrast; never use separator color for meaningful text.
Increase Contrast switches borders to stronger semantic outlines; status also has icon and word.
Typography is SF Pro via semantic text styles; no bundled fonts.
Page title: `.largeTitle.bold()`; workspace name: `.title3.weight(.semibold)`.
Question prompt: `.title3.weight(.semibold)`; body/options: `.body`; metadata: `.subheadline`.
Hashes and comparison codes: `.system(.body, design: .monospaced)` with scalable emphasis.
Only counters use monospaced digits; regular prose uses the system's natural spacing.
Spacing constants: 4, 8, 12, 16, 24, 32 points; page inset 20, compact card inset 16.
Card radius 16; small inset radius 10; pill treatment reserved for status and filters.
Minimum interactive target 44×44 points; row minimum 56, file row typically 76.
No fixed-height prompt or filename containers; wrap titles to accommodate accessibility sizes.
Cards use a one-point outline; no shadow except system sheet elevation.
SF Symbols: `square.stack.3d.up`, `questionmark.bubble`, `tray`, `doc`, `terminal`, `gearshape`.
Use `lock.shield` sparingly for verified identity, never as a blanket promise of endpoint safety.
Transitions: native push/sheet; 180 ms ease-out for filters and expansion.
Completion: one light success haptic after host acceptance, not after tapping Send.
Reduced Motion removes custom movement; Reduce Transparency uses opaque fills.
VoiceOver announces workspace, state, then action; decorative rail and icons are hidden.
Security codes are readable both grouped and character-by-character; never rely on color matching.
Snapshot baselines cover light/dark, small phone, and accessibility text sizes.

## 4. Architecture and dependency boundaries

Use a SwiftPM package named `OrchCore` at `Core/`, with narrow products rather than one giant library.
Compile with Swift 6 concurrency checking after confirming the chosen Xcode baseline.
Keep generated Xcode project settings in `project.yml`, following S2's XcodeGen approach.
Do not copy S2's ad-hoc signing settings into TestFlight configurations.

| Target/product | Owns | May link |
|---|---|---|
| OrchProtocol | Strict JSON, IDs, crypto, envelopes, sealed Drop/push formats | Foundation, CryptoKit |
| OrchDomain | Pairing/decision reducers, typed snapshots, client interfaces | OrchProtocol |
| OrchStorage | SQL repositories, migrations, spool, replay/tombstone stores | Domain, GRDB |
| OrchCustody | Key handles, Security adapters, protected-data bridge | Protocol, Security |
| OrchClient | Pairing/session/bridge orchestration and reconciliation | Domain, storage, custody |
| OrchDemo | FakeRelay, FakeHost, FakePrimary, scenarios, seeded resources | Domain, Protocol, storage |
| OrchApp | SwiftUI, Observation, navigation, notifications delegate | Client, Demo, design tokens |
| NotificationService | Thin NSE adapter and extension-safe push processor | Protocol, narrow push storage/key reader |
| ShareExtension | Item intake, destination picker, protected staging spool | Minimal storage/types, SwiftUI/UIKit |
| TestSupport | Fixed clocks, deterministic entropy, vector loaders | Test targets only |

Physically separate extension-safe push storage from full workspace repositories.
The NSE must not transitively link FakeHost, full app UI, device signing, or network clients.
The share extension must not link device signing, PK, WK custody, or FakeHost.
Use `APPLICATION_EXTENSION_API_ONLY` for shared extension products and audit transitive imports.
No dependency on the Python reference implementation or sibling checkout paths at runtime.
Bundle checked-in vector resources with a recorded upstream revision/hash for tests.
Reject a monolithic Core product: importing a parser must not also grant convenient signing access.
Reject TCA/Redux frameworks for this size; explicit state machines plus Observation are sufficient.
Reject third-party networking/crypto frameworks; Foundation URLSession and CryptoKit cover the need.
GRDB is the one proposed runtime third-party dependency, pinned and license-reviewed.
XcodeGen is a pinned build tool; CI pins action revisions and records Xcode/runtime versions.

### 4.1 The seam is encrypted transport, not just mock view data

`RelayTransport: Sendable` provides challenge/login, mailbox send/poll, and directory/blob operations.
Its request/response types carry validated routing IDs and opaque bytes, never question text.
Split pairing bootstrap from authenticated transport so epoch-0 enrollment needs no existing session.
`WorkspaceHost: Sendable` is the app-facing typed client capability, implemented by `BridgeWorkspaceHost`.
It exposes snapshots/events, submitDecision, file operations, and supported workspace commands.
Views depend on that capability and repositories, never a URLSession or FakeHost instance.
`BridgeWorkspaceHost` serializes, seals, signs, sends, verifies, and reduces authoritative responses.
Demo replaces RelayTransport with `InProcessRelayTransport`; it does not replace that client path.
The transport passes bytes through FakeRelay to FakeHost's parser and validator.
FakeRelay checks routing/session/membership, holds opaque mailboxes, and simulates delay/loss.
FakeHost decrypts, verifies, applies scopes/idempotency, and signs its responses with its own WSK.
FakePrimary alone holds the synthetic PK and certificate authority behavior.
Use an injectable clock, sleeper, entropy source, and fault policy; no hardcoded wall-clock sleeps.
Production entropy is system randomness; deterministic entropy exists only in scenario/test composition.
Future `HTTPSRelayTransport` replaces the carrier without changing views, reducers, or crypto.
Undefined host view APIs live behind a versioned proposed DTO mapping, not asserted as protocol v2.
Do not claim Tickets/Files snapshot interoperability until their mappings have contract fixtures.

### 4.2 State and concurrency

An `@MainActor @Observable AppModel` owns environment, route selection, and workspace summaries.
Each workspace gets an observable screen model fed by a `WorkspaceSession` actor.
A session owns bridge sequences, pending request IDs, current epoch, reconnection, and subscriptions.
Repository actors serialize writes; return immutable `Sendable` domain values to the UI.
Use structured tasks for screen lifetime; cancel polling on logout, environment switch, or background.
Do not use detached tasks to escape actor isolation or hold on to sensitive view state.
Bound synchronization to three active workspace polls, with jittered backoff and cancellation.
Persist request identity before sending; uncertain outcomes retry the same logical decision ID.
Refresh the envelope as protocol retry rules permit without inventing a new decision.
On stale epoch, verify and install a strictly newer grant, then reseal under the new epoch.
Never lower a pinned card sequence, epoch, or replay high-water mark.
Backgrounding pauses foreground synchronization; no promise of a continuously running host on iOS.
Protected-data loss closes plaintext stores, cancels signing, drops key caches, and masks UI snapshots.
System keychain/file errors are authoritative even if an app lifecycle callback arrives late.

### 4.3 FakeHost pairing and simulated authority

FakeHost creates real suite-2 WSK/WXK, an owner delegation, card, WK epoch, and offer records.
FakePrimary creates its separate PK and primary agreement key within the Demo namespace.
Offer creation generates secret S and SAS nonce, expiry, scope, and the canonical pinned link.
The phone uses its own custody backend to generate `dk_sig` and `dk_kx` and derive its device ID.
FakeHost performs protocol §8.6/§8.3 checks in order, including silent drops and refusal budgets.
It consumes an offer once, permits same-key pending retries, and rejects competing claimants.
Host approval is an explicit scenario input; a successful cryptographic request does not imply approval.
For a first device, FakeHost seals and signs a real cert request addressed to FakePrimary.
FakePrimary verifies it, enforces one open request per workspace, and draws its own nonce afterward.
It publishes a PK-signed challenge; the phone verifies pins, workspace, both keys, and expiry.
Only a second explicit primary approval produces a certificate for those exact stored keys.
Then FakeHost publishes certificate → WK grant → member list, preserving the protocol ordering.
The phone logs in through a real challenge/signature exchange and opens its signed WK grant.
No WK leaves FakeHost before the certificate is valid; test this as an invariant, not just a screen state.
The existing-certificate path validates ownership, expiry, revocation, and both key bindings.
Preserve host request records and state across app restarts; otherwise retries cannot be demonstrated honestly.
Persist Demo authority material only in a Demo-specific protected store/keychain namespace.
FakeHost's presence on the phone is a simulation privilege, never a shipping real-workspace mode.

## 5. Keys and local storage

### 5.1 Custody

`DeviceKeyCustody` exposes create/load identity, public keys, sign(domainBytes), agree(peer), and delete.
Private key export is absent from the interface; use typed handles rather than raw scalar properties.
A separate `WorkspaceKeyVault` installs verified grants and supplies purpose-derived keys.
The client performs domain separation; views cannot ask for arbitrary signatures.
Use two P-256 key pairs (`dk_sig`, `dk_kx`) as the wire contract requires.
D49's “no key split” means no extra human-versus-transport signing identity, not one EC key pair.
On physical iPhone use Secure Enclave keys with `WhenPasscodeSetThisDeviceOnly` and private-key usage.
Do not add `.userPresence` or `.biometryCurrentSet`; that would contradict D49.
S1's unlocked Mac test class is evidence about crypto interoperability, not the phone's final policy.
Simulator uses CryptoKit software P-256 behind the same interface, with explicit simulated lock state.
Never fall back silently to software for a real-workspace identity on a physical phone.
TestFlight Demo uses real phone custody when available; missing passcode gives the real setup error.
Synthetic host/primary keys may be software keys but are never advertised as the phone's device custody.
Only tests import deterministic vector scalars; generated app identities use fresh randomness.
Signature assertions verify raw 64-byte r||s; do not compare randomized ECDSA outputs byte-for-byte.

### 5.2 Storage choice and protection

Choose SQLite through GRDB with one `DatabaseQueue` per workspace and explicit SQL migrations.
It provides inspectable schemas/transactions without writing a new C resource-management layer.
Direct sqlite3 is rejected for the main store: statement lifetimes and migrations add avoidable risk.
SwiftData is rejected: explicit multi-process stores, tombstones, and wire IDs matter more than model magic.
GRDB supplies serialization primitives; app actors still own domain ordering and cancellation.
See [GRDB's concurrency implementation](https://github.com/groue/GRDB.swift/blob/master/GRDB/Core/DatabaseWriter.swift).

Proposed layout, where IDs are canonical hex and `environment` is `demo` or a configured real realm:

```text
App private Library/Application Support/orch/<environment>/
  catalog.sqlite                       # protected workspace summaries
  workspaces/<ws>/workspace.sqlite     # questions, tickets, sync state, outbox
  workspaces/<ws>/blobs/                # authenticated encrypted downloads
  workspaces/<ws>/previews/             # short-lived plaintext, Complete
  demo-host/                           # synthetic authority/state, Demo only
App Group group.<bundle>.push/<environment>/<ws>/
  push.sqlite                          # replay timestamps and removal generation
App Group group.<bundle>.share/<environment>/
  destinations.json                    # minimal protected names/IDs/scopes
  workspaces/<ws>/jobs/<job-id>/        # manifest + staged attachment, atomic ready marker
```

Use separate push and share App Groups to avoid granting the NSE access to attachment staging.
App belongs to both; NSE belongs only to push; share extension belongs only to share.
Full workspace databases and previews use `NSFileProtectionComplete`, including SQLite sidecars.
Close/checkpoint before protection loss where possible; tolerate unavailable files without migration/reset.
Shared attachment staging uses Complete; it is readable only while unlocked and has an expiry janitor.
Push replay metadata alone uses CompleteUntilFirstUserAuthentication, with no labels in it.
Exclude caches, staging, Demo authority, and workspace databases from backup; re-pair after reinstall/restore.
Protection is device data protection, not SQLCipher; do not claim a separate SQL encryption layer.
Use bounded file streaming; never load a 25 MiB attachment plus multiple copies into an extension.
Copy to a temporary protected directory, validate size/type, fsync as needed, then atomically mark ready.
Do not store secret fragments, plaintext previews, or filenames in UserDefaults or logs.

Keychain groups are separate from App Groups and require explicit signed entitlements:

- App-only group: DK handles, certificate association, WK epochs, pairing secrets, relay sessions.
- App + NSE push group: derived `K_push(ws, epoch)`, pinned WSK, and minimal membership generation.
- Share extension: no keychain access to device identity or workspace keys.
- All items: non-synchronizable, tagged by environment/person/workspace/purpose where applicable.
- App-only secrets: WhenPasscodeSetThisDeviceOnly; derived push keys: AfterFirstUnlockThisDeviceOnly.

The looser push class is intentional so locked-phone alerts can open after first unlock.
It grants access only to notification content, not WK, decisions, or Drop content.
Passcode removal deletes items in the stricter class; detect missing identity and wipe dependent state.
These accessibility properties follow [Apple's keychain class documentation](https://developer.apple.com/documentation/security/ksecattraccessiblewhenpasscodesetthisdeviceonly).
Keep prior push epochs only as long as needed for accepted delayed payloads and retained membership.
Retain WK epochs according to accessible cached content; new members receive current epoch only.
App Group availability failure is an error, never a fallback to private or bundled key material.

### 5.3 Wipe protocol and process races

Removal first marks a durable workspace tombstone/generation in the shared coordination stores.
Serialize NSE reads/writes and app removal with a bounded cross-process lock/transaction.
Cancel app work, reject new share jobs, and delete WK/push keys and per-workspace files/sidecars.
Remove delivered/pending notifications by verified workspace identity and clear previews and routes.
Update the destination index atomically; scan again for jobs racing the tombstone.
Retain only routing identifiers and minimal cleanup status outside the deleted workspace container.
On next launch finish interrupted deletion before constructing any workspace session.
A push processor rechecks generation before handing off content; removal cannot recall an already delivered alert.
Run a second notification cleanup after wipe; document the unavoidable OS delivery race.
SQLite secure-delete is not a promise of flash erasure; protection and key deletion are the meaningful controls.
Never delete the common device key when leaving one of several workspaces.

## 6. Push architecture and realistic Demo behavior

APNs registration is modeled per `(device_id, workspace_id)`, including topic and APNs environment.
The OS token belongs to the installation; upsert its current value for every active membership.
Token changes reconcile all memberships; remove only the departing workspace's server registration.
Unregister the app only after the final workspace, subject to outstanding cleanup handling.
TestFlight uses the distribution/production APNs environment even with a development relay hostname.
Demo records registrations in FakeRelay; it does not upload the token or require an APNs credential.
Ask for local-notification permission in Demo; expose registration states as simulated in diagnostics.

Extract a pure `PushProcessor` from S2's approach; keep the actual NSE as a thin lifecycle adapter.
Parse the exact outer JSON string in APNs field `o`, cap it, open AEAD, verify WSK, then validate payload.
Enforce timestamp/replay checks and persist the high-water mark before displaying anything.
Use byte-exact IDs for replay/notification keys; Swift canonical-equivalent strings must not collapse IDs.
The NSE reads only derived push keys, pinned WSK, membership generation, and replay state.
It performs no network fetch, epoch refresh, device signing, file download, or FakeHost invocation.
Return newly built notification content; discard untrusted relay title, sound, category, and userInfo.
Use an exactly-once completion gate shared with timeout handling; generic fallback never uses relay text.
Use workspace thread grouping; local entity key is `(environment, ws, id)` with byte-safe encoding.
For `question.closed`, remove matching previously delivered requests and present the verified closure.
APNs collapse ID is a provider HTTP header set by the relay, not something an NSE can set afterward.
A bounded digest of workspace/entity identity is the proposed collapse ID; confirm its wire policy later.
Thread grouping is not replacement, and collapse is not a guaranteed transactional notification update.

Demo FakeHost generates real signed/sealed push bytes; the app passes them through PushProcessor.
Then a local-notification adapter schedules the verified result and performs simulated replacement.
Local notifications do not invoke the NSE; Demo diagnostics must call this “local notification simulation”.
When suspended, FakeHost does not keep running; pre-scheduled local examples have fixed, disclosed behavior.
Use a Demo scenario to schedule “question” and “answered elsewhere” while the app remains available.
NSE invocation is tested separately with remote-style simulator injection and later real APNs.
Apple describes NSE modification specifically for remote notifications in its [notification guide](https://developer.apple.com/library/archive/documentation/NetworkingInternet/Conceptual/RemoteNotificationsPG/ModifyingNotifications.html).

## 7. Test strategy and build/release path

### 7.1 Core tests with `swift test`

Run `swift test --package-path Core` on macOS without a simulator, network, or sibling repository.
Bundle suite-2 vectors and assert strict parsing, sealing, ECDH, signatures, and all relevant negative cases.
Cover certs, cards, grants, relay auth, bridge ordering, pairing, push, Drop, and detached decisions.
Include both high-S accepted signatures and invalid scalar/key cases according to the actual protocol.
Test reducers with fixed clocks at expiry boundaries, lost responses, duplicate sends, and epoch rotation.
Pairing tests include the R1 different-key attack, stale PK pin, host-forged challenge, and primary offline.
Assert no grant before certification and no acceptance before persisted pin/certificate verification.
Question tests cover compare-and-set races, changed content, cross-workspace replay, and uncertain delivery.
Storage tests use temporary directories and real SQL migrations; test interrupted wipes and spool claims.
Concurrency tests race push/open/close/remove and check maximum timestamps and handler-at-most-once.
Core tests cannot prove keychain entitlement access, data protection, camera behavior, or Secure Enclave.
Keep Apple-specific integration tests in an iOS host test target instead of weakening Core portability.

### 7.2 Simulator and XCUITest

Use `xcodebuild test` on the generated workspace/scheme with an explicitly selected simulator UDID.
Launch options are parsed once by the composition root; no view reads environment variables directly.
Proposed flags: `--demo`, `--scenario <name>`, `--reset-demo`, `--seed <int>`, `--clock <ISO8601>`.
Test-only flags: `--ui-testing`, `--fault <name>`, `--initial-route <route>`, `--disable-animations`.
Test flags are rejected in distribution builds; TestFlight exposes a curated Demo control screen instead.
All reset operations are limited to the Demo namespace and cannot reach a future real realm.
Fixed test IDs include `home.workspace.<id>`, `pair.sas`, `pair.certCode`, and `decision.confirm`.
Assert state and visible text; screenshots support review but do not replace behavioral assertions.

Required scenarios:

- Empty launch → Demo → two workspace cards → navigation restoration after relaunch.
- Pasted invitation → host comparison → primary offline → cert challenge → join.
- Existing certificate joins a second workspace; host and primary codes never coexist.
- Invalid pin, competing device, expired offer, denied scope, and camera denied fallback.
- Review full long question → sign → accepted; concurrent answer and changed-question recovery.
- Airplane-like transport fault preserves cached reading and drafts without false sent state.
- Drop receive/preview/export, staged share import, expiry, cancellation, and failed retry.
- Logout one workspace leaves the other's database, keys, and notifications intact.
- Crash at each wipe phase resumes cleanup; revoked device becomes unusable.
- Dynamic Type, VoiceOver labels, dark mode, small display, keyboard, and Reduce Motion.

### 7.3 Sealed push and extension tests

Generate `.apns` fixtures from the same Demo/test keys and clock, never production material.
Fixture structure is `aps.alert` generic text, `aps.mutable-content = 1`, and `o` as a JSON string.
Run `xcrun simctl push <udid> <bundle-id> <fixture.apns>` with the app installed and enrolled workspace.
Cases: question, newer closure, replay, stale timestamp, unknown epoch/workspace, and forged WSK signature.
Also inject malicious outer title/category/userInfo and prove no such fields survive processing.
Verify extension-process evidence on the selected Xcode/runtime; injection alone is not evidence of NSE execution.
If that runtime does not launch the NSE, mark the lifecycle test unsupported, not passed.
Run hosted adapter tests and pure processor tests regardless; keep the uncovered device check explicit.
S2's in-app NSE self-test is useful behavior coverage but not sandbox, entitlement, or APNs-collapse proof.
For deterministic timeouts, call the thin adapter's expiry path and assert its handler fires once.
Physical-device tests cover locked/first-unlock behavior, actual APNs replacement, and shared keychain access.

### 7.4 Share extension and CI

A UI-test-only fixture screen presents a genuine `UIActivityViewController` with file/text/URL providers.
XCUITest selects “Share to orch,” chooses a destination, saves, returns to the app, and verifies receipt.
This exercises the installed extension process rather than reproducing its compose view inside the app.
Test canceled provider loads, delayed providers, excessive size, deleted destination, and app-not-running staging.
Use a seeded Files item for an additional system-host integration path where the runtime permits it.
Photos/Files sharing on physical iPhone remains a release checklist item; simulator UI varies by runtime.
Check the resulting spool's ownership, protection, and deletion with hosted integration assertions.
Do not depend on fragile pixel coordinates or a share-sheet extension order.

GitHub Actions has two jobs: fast Core tests, then macOS/Xcode build plus simulator integration/UI tests.
Pin a supported macOS image/Xcode pair after checking availability; do not rely on `macos-latest` drift.
Resolve pinned packages, run XcodeGen, create/boot one known simulator, and wait for boot completion.
Use isolated DerivedData and simulator state per job; cache dependencies keyed by lockfile and Xcode.
Archive `.xcresult`, sanitized failure logs, and screenshots; redact content outside synthetic fixtures.
PR CI requires no signing secrets and no network service once dependencies are resolved.
Physical Secure Enclave tests report skipped where unavailable; they are never counted as passing custody proof.
Distribution is a separate manually dispatched workflow with protected signing/App Store Connect credentials.
Archive all three targets with matching App Group/keychain entitlements and signed provisioning profiles.
Upload a Demo-capable TestFlight build; never include APNs `.p8` material in the app or repository.
Demo acceptance: install, enter Demo, pair, answer, share a file, simulate closure, and wipe without a relay.
Real-device release checks remain required before claiming production pairing, custody, or push readiness.

## 8. Inconsistencies, risks, and decisions still needed

1. **D49 versus older biometric language.** README, threat model, §7 and D46 still say Face ID per signature.
   Follow D49 on iPhone; amend those descriptions and tests before the real release.
2. **Native app still listed as a non-goal.** Architecture §2 contradicts D45 and its own mobile chapter.
   Treat that line as obsolete, not a reason to build a PWA.
3. **Protocol remains browser-oriented.** It calls mobile a PWA, suite 1 primary, and uses Web Push terminology.
   Freeze a native suite-2 profile; do not ship suite negotiation or port browser runtime assumptions.
4. **Two cryptographic keys versus “no key split”.** Protocol requires signing and agreement keys.
   Clarify that D49 removes a human/transport signing split, not the `dk_sig`/`dk_kx` distinction.
5. **Native replacement for WebAuthn is incomplete.** §8.3 still registers a passkey; §8.7 binds assertions.
   Detached decision signatures exist, but Type/Factory assertion mappings need a native contract amendment.
6. **Pairing URL discrepancy.** Architecture omits `pk_pin` in its example and names `/pair`; protocol uses `/app/pair`.
   Use the five-field fragment and define both URL routing and associated-domain paths explicitly.
7. **Custom relay universal links.** An arbitrary self-hosted domain cannot be assumed associated with this app.
   Paste/QR with origin review remains the reliable path; define supported associated domains and redirects.
8. **Multi-user mismatch.** Architecture allows an authorized non-owner person; §8.3 insists on owner identity.
   Prototype is same-person only; do not weaken the pin check to simulate collaboration.
9. **APNs transport envelope lacks a complete normative profile.** S2 uses string field `o`; protocol says Web Push.
   Specify outer APNs keys, topic/environment, provider headers, size overhead, and registration API.
10. **NSE cannot set provider collapse headers.** Architecture assigns `apns-collapse-id` to the extension.
    Relay sets it; NSE does best-effort delivered-item removal; grouping and replacement need separate tests.
11. **“iOS has no silent push” is inaccurate.** The actionable constraint is unreliable background delivery.
    Keep visible closures as product policy; do not base correctness on silent refresh.
12. **Dropping a payload is not suppressing an OS notification.** NSE rejection/timeout may still yield an alert.
    Generic fallback is honest; a malicious APNs sender can omit extension-triggering fields entirely.
13. **Push freshness assumes ordered host timestamps.** Same-millisecond question/closure can violate strict `>`.
    FakeHost advances timestamps per entity; specify monotonic event order or timestamp allocation for real hosts.
14. **Push key retention and epoch races need policy.** Locked NSE cannot fetch a new WK; removed keys prevent opening.
    Publish derived keys before registration, tolerate generic alerts, and reconcile on next foreground.
15. **Offline logout versus immediate deregistration.** Wiping keys may remove credentials needed for server cleanup.
    Define a narrow logout operation/credential lifetime; show pending state rather than promising completion.
16. **Extension signing scope is intentionally absent.** Share cannot reliably perform foreground device signatures.
    Stage for the app in M0; later background-upload work needs an explicit authorization model.
17. **Human-readable exact text is underspecified for non-question actions.** Protocol retains WebAuthn `shown` rules.
    Define canonical action summaries and hash binding before enabling general Factory/Type approvals.
18. **Host APIs remain incomplete.** Tickets snapshots, `new_ticket`, `member_remove`, and `drop_rewrap` lack full vectors.
    Mark demo mappings provisional and require contracts before replacing transport with real connectivity.
19. **S1/S2 are spikes, not production custody.** S1 uses a Mac accessibility class; S2 stores key material in files.
    Keep their vectors and boundary lessons; replace storage and signing configuration as proposed here.
20. **App Group and notification race limits.** Actors do not coordinate extension processes or retract OS snapshots.
    Use transactions/generations, test interrupted wipes, and avoid claiming perfect notification recall.
21. **Demo authority shares the phone process.** FakePrimary's PK is necessarily accessible to demo implementation.
    Namespace it, prohibit real transport in Demo, and never interpret Demo certification as security evidence.
22. **Protection tests have hardware limits.** Simulator software keys and synthetic lock flags cannot prove D49.
    TestFlight with passcode, lock, reboot, and actual Secure Enclave remains a required acceptance gate.

## 9. Implementation order and exit criteria

First build Core vectors, typed transport, fake authorities, and pairing reducer without screens.
Then build Home/Needs you, workspace stores, real review/sign values, and deterministic Demo scenarios.
Next add Drop, the share spool, and interruption-safe logout; verify per-workspace isolation early.
Then integrate PushProcessor/NSE and notification routing, with explicit simulation diagnostics.
Finally run accessibility/UI coverage and package the signed Demo build for the iPhone checklist.
M0 is complete when every enabled action has a persisted, testable simulated outcome or a truthful failure.
Real relay integration is a later adapter milestone gated by the contract gaps above, not a rewrite of the UI.
