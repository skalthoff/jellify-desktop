export const meta = {
	name: 'finalize-lyrebird-desktop',
	description:
		'Drive lyrebird-desktop to "polished": multi-wave audit → triage → fix (bugs/polish) + feature track (M3) + M4 distribution prep → adversarial review → auto-merge, looping until POLISH_TARGETS.md passes or the token budget / wave cap / drain ceiling stops it.',
	whenToUse:
		'Full development + finalization of lyrebird-desktop. Spawns the area-auditor/problem-triager/area-fixer/adversarial-reviewer agents plus a feature-builder track. Honors hotspot locks and the drain ceiling. Pass args to scope it (see CONFIG).',
	phases: [
		{ title: 'Preflight', detail: 'branch + POLISH_TARGETS gate + issue census + drain check' },
		{ title: 'Audit', detail: '8 parallel area-auditors, one per slice' },
		{ title: 'Triage', detail: 'problem-triager → ordered bug/polish fix manifest' },
		{ title: 'Select', detail: 'pick M3 feature batch + M4 distribution batch from the backlog' },
		{ title: 'Build', detail: 'area-fixer (bugs) + feature-builder (feat/dist), worktree-isolated, ≤1 per hotspot' },
		{ title: 'Review', detail: 'adversarial-reviewer per PR; Opus on dispute; auto-merge on approve' },
		{ title: 'Release gate', detail: 'M4 release-readiness verification (no live signing)' },
		{ title: 'Report', detail: 'final polish-gate + wave summary' },
	],
}

// ---------------------------------------------------------------------------
// CONFIG — defaults match the "full arc, run until polished, auto-merge" choice.
// Override any of these by passing them in Workflow `args`.
// ---------------------------------------------------------------------------
const cfg = {
	includeFeatures: args && args.includeFeatures != null ? args.includeFeatures : true,
	includeDist: args && args.includeDist != null ? args.includeDist : true,
	autoMerge: args && args.autoMerge != null ? args.autoMerge : true,
	maxWaves: args && args.maxWaves != null ? args.maxWaves : null, // null → derive from budget
	featBatchPerWave: args && args.featBatchPerWave != null ? args.featBatchPerWave : 3,
	distBatchPerWave: args && args.distBatchPerWave != null ? args.distBatchPerWave : 2,
	// Per-wave PR ceiling. Kept below the pipeline's 5-open-PR drain ceiling.
	buildCeiling: args && args.buildCeiling != null ? args.buildCeiling : 4,
	featMilestone: args && args.featMilestone ? args.featMilestone : 'M3 — macOS polish',
}

const WAVE_BUDGET_SECONDS = 14400 // 4h — what preflight hands the agents' Scripts/wave-budget.sh
const WAVE_TOKEN_COST = 400000 // rough per-wave output-token estimate, for budget-derived wave cap
const DRAIN_CEILING = 5 // open fix/* PRs that abort new audit/fix work

// No silent caps: derive the wave cap and announce it.
const MAX_WAVES =
	cfg.maxWaves != null
		? cfg.maxWaves
		: budget.total
			? Math.max(1, Math.min(8, Math.floor(budget.total / WAVE_TOKEN_COST)))
			: 3

// ---------------------------------------------------------------------------
// SCHEMAS
// ---------------------------------------------------------------------------
const PREFLIGHT_SCHEMA = {
	type: 'object',
	properties: {
		branch: { type: 'string' },
		polished: { type: 'boolean' },
		polishChecks: {
			type: 'array',
			items: {
				type: 'object',
				properties: { name: { type: 'string' }, pass: { type: 'boolean' }, detail: { type: 'string' } },
				required: ['name', 'pass'],
			},
		},
		openP0: { type: 'integer' },
		openBugs: { type: 'integer' },
		openFeatM3: { type: 'integer' },
		openDist: { type: 'integer' },
		openFixPRs: { type: 'integer' },
		openFixPRNumbers: { type: 'array', items: { type: 'integer' } },
		notes: { type: 'string' },
	},
	required: ['polished', 'openP0', 'openFixPRs', 'notes'],
	additionalProperties: true,
}

const AUDIT_SCHEMA = {
	type: 'object',
	properties: {
		slice: { type: 'string' },
		candidatesFound: { type: 'integer' },
		issuesFiled: { type: 'integer' },
		issueNumbers: { type: 'array', items: { type: 'integer' } },
		autoDowngrade: { type: 'boolean' },
		notes: { type: 'string' },
	},
	required: ['slice', 'issuesFiled', 'notes'],
	additionalProperties: true,
}

const TRIAGE_SCHEMA = {
	type: 'object',
	properties: {
		manifest: {
			type: 'array',
			items: {
				type: 'object',
				properties: {
					issue: { type: 'integer' },
					slice: { type: 'string' },
					hotspot: { type: 'string' },
					priority: { type: 'string' },
					effort: { type: 'string' },
				},
				required: ['issue', 'hotspot'],
			},
		},
		rejected: {
			type: 'array',
			items: {
				type: 'object',
				properties: { issue: { type: 'integer' }, reason: { type: 'string' } },
			},
		},
		notes: { type: 'string' },
	},
	required: ['manifest'],
	additionalProperties: true,
}

const SELECT_SCHEMA = {
	type: 'object',
	properties: {
		items: {
			type: 'array',
			items: {
				type: 'object',
				properties: {
					issue: { type: 'integer' },
					slice: { type: 'string' },
					hotspot: { type: 'string' },
					title: { type: 'string' },
					kind: { type: 'string' },
				},
				required: ['issue', 'hotspot'],
			},
		},
		notes: { type: 'string' },
	},
	required: ['items'],
	additionalProperties: true,
}

const BUILD_SCHEMA = {
	type: 'object',
	properties: {
		issue: { type: 'integer' },
		prOpened: { type: ['integer', 'null'] },
		branch: { type: 'string' },
		hotspotsClaimed: { type: 'array', items: { type: 'string' } },
		buildGate: { type: 'string', enum: ['pass', 'fail', 'skipped'] },
		resolved: { type: 'boolean' },
		notes: { type: 'string' },
	},
	required: ['issue', 'prOpened', 'buildGate', 'resolved', 'notes'],
	additionalProperties: true,
}

const REVIEW_SCHEMA = {
	type: 'object',
	properties: {
		pr: { type: ['integer', 'null'] },
		outcome: {
			type: 'string',
			enum: ['approve', 'request-changes', 'dispute-needs-opus', 'no-pr', 'error'],
		},
		checklistViolations: { type: 'integer' },
		merged: { type: 'boolean' },
		hotspotReleased: { type: ['string', 'null'] },
		notes: { type: 'string' },
	},
	required: ['outcome', 'notes'],
	additionalProperties: true,
}

const RELEASE_GATE_SCHEMA = {
	type: 'object',
	properties: {
		checks: {
			type: 'array',
			items: {
				type: 'object',
				properties: { name: { type: 'string' }, pass: { type: 'boolean' }, detail: { type: 'string' } },
				required: ['name', 'pass'],
			},
		},
		releaseReady: { type: 'boolean' },
		blockers: { type: 'array', items: { type: 'string' } },
		notes: { type: 'string' },
	},
	required: ['releaseReady', 'notes'],
	additionalProperties: true,
}

// ---------------------------------------------------------------------------
// SLICES + hotspot helpers
// ---------------------------------------------------------------------------
const SLICES = [
	'slice:client',
	'slice:models',
	'slice:state',
	'slice:tests',
	'slice:screens',
	'slice:components',
	'slice:audio',
	'slice:scaffold',
]

// Normalize a slice/hotspot tag to one of the three real hotspot keys, or 'none'.
function hotspotOf(item) {
	const h = (item && item.hotspot ? String(item.hotspot) : '').toLowerCase()
	if (h.includes('client')) return 'client'
	if (h.includes('test')) return 'tests'
	if (h.includes('appmodel') || h.includes('scaffold') || h.includes('lyrebirdapp')) return 'appmodel'
	if (h && h !== 'none') return 'none'
	const s = (item && item.slice ? String(item.slice) : '').toLowerCase()
	if (s.includes('client')) return 'client'
	if (s.includes('tests')) return 'tests'
	if (s.includes('scaffold')) return 'appmodel'
	return 'none'
}

// Enforce ≤1 in-flight item per hotspot and a per-wave ceiling. Returns selected + deferred.
function pickWork(allItems, ceiling) {
	const seen = new Set()
	const selected = []
	const deferred = []
	for (const it of allItems) {
		const h = hotspotOf(it)
		if (selected.length >= ceiling) {
			deferred.push(it)
			continue
		}
		if (h !== 'none' && seen.has(h)) {
			deferred.push(it)
			continue
		}
		if (h !== 'none') seen.add(h)
		selected.push({ ...it, _hotspot: h })
	}
	return { selected, deferred }
}

function builderAgentType(item) {
	return item.builder === 'area-fixer' ? 'area-fixer' : 'claude'
}

// ---------------------------------------------------------------------------
// PROMPTS
// ---------------------------------------------------------------------------
function preflightPrompt(w) {
	return `Preflight for wave ${w} of the lyrebird-desktop finalization pipeline. You are read-mostly; you only WRITE the .wave-start marker. Run these and report results.

1. \`git branch --show-current\` — record it. If it is \`main\` or a \`claude/*\` branch, just record it (do not switch).
2. \`Scripts/wave-budget.sh start ${WAVE_BUDGET_SECONDS}\` — starts the wave budget so downstream agents' \`Scripts/wave-budget.sh remaining\` works.
3. POLISH_TARGETS.md gate: read it, and for every target whose \`check:\` line is a real shell command (not a comment / placeholder), RUN it. A target passes iff its command exits 0. Report one {name, pass, detail} per target. \`polished\` = every runnable check passed.
4. Issue census via \`gh\`:
   - openP0 = \`gh issue list --state open --label 'priority:p0' --json number -q 'length'\`
   - openBugs = open \`kind:bug\`
   - openFeatM3 = open \`kind:feat\` in milestone "${cfg.featMilestone}"
   - openDist = open \`area:dist\` (or milestone M4) issues
5. Drain check: \`gh pr list --state open --search 'head:fix/' --json number\` → openFixPRs (count) + openFixPRNumbers (the numbers).

Return the structured PREFLIGHT object. Do not file issues, open PRs, or change code.`
}

function auditPrompt(slice, w) {
	return `You are auditing ${slice}. Wave ${w} of the lyrebird-desktop adversarial pipeline.

Read CLAUDE.md fully (especially "Deferred / known-open work" and "Runtime gaps — common patterns") and follow your agent definition (.claude/agents/area-auditor.md) EXACTLY. Default verdict: findings: []. Empty output on a quiet slice is success.

Pre-flight: \`git branch --show-current\`; de-dup against open issues with \`gh issue list --state open --search "<keyword>"\` before filing anything. Honor the five-part falsifiability gate and the auto-downgrade rule (5+ candidates ⇒ file none, surface them).

File confirmed findings with \`gh issue create\` using the required labels incl. \`source:auto-audit\`. Then return the structured AUDIT summary for this slice.`
}

function triagePrompt(w, filedNumbers) {
	return `You are the problem-triager for wave ${w}. Follow .claude/agents/problem-triager.md EXACTLY. Do NOT write code or open PRs.

The wave start is in \`.wave-start\`. The issues filed by auditors this wave are: ${filedNumbers.length ? filedNumbers.map((n) => '#' + n).join(', ') : '(none — query source:auto-audit since wave start yourself)'}.

For each: reject \`kind:feat\` (close with the standard comment), re-check the five falsifiability fields, reconcile priority/effort labels, and tag hotspot requirements (client.rs / tests.rs / AppModel.swift+LyrebirdApp.swift). Build the ordered fix manifest (priority desc, effort asc, non-hotspot first, ≤1 entry per hotspot, cap 6). IGNORE \`Scripts/wave-budget.sh\` — the orchestrator governs the budget; do NOT emit an empty manifest because wave-budget remaining is low/zero (treat it as ample). Return the structured TRIAGE object (manifest + rejected).`
}

function featSelectPrompt(w, count, milestone) {
	return `You are selecting the FEATURE batch for wave ${w}. Read-only + \`gh\`. Do NOT write code.

Pick up to ${count} \`kind:feat\` issues from milestone "${milestone}" that are the best next implementation targets. Prefer priority p0 > p1 > p2, then effort S > M (avoid L/XL unless p0). Requirements:
- Skip any issue that already has an open \`fix/*\` or \`feat/*\` PR (check \`gh pr list --state open --search "<issue keyword>"\` or by \`Closes #n\`).
- Skip issues blocked on unlanded core FFI (read CLAUDE.md "Deferred / known-open work").
- For each chosen issue, determine its \`slice:\` and its hotspot: one of client | tests | appmodel | none (appmodel = touches AppModel.swift or LyrebirdApp.swift, i.e. slice:scaffold).
Return the structured SELECT object: items:[{issue, slice, hotspot, title, kind:"feat"}].`
}

function distSelectPrompt(w, count) {
	return `You are selecting the M4 DISTRIBUTION batch for wave ${w}. Read-only + \`gh\`. Do NOT write code.

Pick up to ${count} M4 / \`area:dist\` issues that an agent can complete WITHOUT live Apple credentials — e.g. CI workflow YAML, hardened-runtime entitlements plists, packaging scripts (make-dmg/make-bundle), appcast generator, Sparkle SPM wiring, .desktop/flatpak manifests. EXCLUDE anything that requires actually signing, notarizing, or uploading with a real Developer ID (those need the user). For each, determine slice + hotspot (client|tests|appmodel|none) and kind. Return the structured SELECT object: items:[{issue, slice, hotspot, title, kind}].`
}

function fixerPrompt(item, w) {
	const hs = item._hotspot === 'none' ? '[]' : `[${item._hotspot}]`
	return `slice: ${item.slice || '(infer from issue labels)'}
issues: [#${item.issue}]
hotspots-required: ${hs}
wave: ${w}

Follow .claude/agents/area-fixer.md EXACTLY — EXCEPT do NOT abort on the wave-budget gate. The orchestrator governs the overall budget; if \`Scripts/wave-budget.sh remaining\` is unavailable OR reports 0/low, treat remaining as ample (~${WAVE_BUDGET_SECONDS}s) and proceed.

Pre-flight: \`git branch --show-current\`; if on main/claude/*, create \`fix/${item.issue}-<slug>\` off \`origin/main\`. Make the MINIMAL change that closes #${item.issue} — nothing else. Run the build gates (cargo fmt/clippy/test for Rust; \`swift build\` for Swift; regenerate xcframework + bindings in the SAME commit for FFI-adjacent changes). No AI attribution, no Co-Authored-By, no banned comments. Open a PR with \`Closes #${item.issue}\` and the \`pipeline:\` block. Return the structured BUILD object (set prOpened to the PR number, or null if you aborted).`
}

function featureBuilderPrompt(item, w) {
	const hs = item._hotspot === 'none' ? 'none' : item._hotspot
	return `You implement ONE feature for lyrebird-desktop — a NATIVE desktop Jellyfin client (Rust \`core/\` exposed via UniFFI; \`macos/\` SwiftUI app consuming LyrebirdCore). Wave ${w}.

Issue: #${item.issue} — "${item.title || ''}" (${item.slice || 'unknown slice'}, kind:${item.kind || 'feat'}). Hotspot: ${hs}.

MANDATORY discipline (this is a finalization pipeline, not a hack):
1. \`git branch --show-current\`. If on \`main\` or a \`claude/*\` branch, create \`feat/${item.issue}-<slug>\` off \`origin/main\` first.
2. Read the issue body in full (\`gh issue view ${item.issue}\`). Read CLAUDE.md fully — especially "Runtime gaps — common patterns" (sync FFI on MainActor, paged-cache-only resolution, optimistic-UI-without-echo, tuple-destructure awaits) and the build gates. Read ROADMAP.md for the M3 design bar (Apple Music / Spotify / Doppler polish).
3. If the hotspot is not 'none', claim it: \`Scripts/area-lock.sh claim ${hs} pending feature-builder-${item.issue}\`. If LOCKED, abort cleanly (return prOpened:null, resolved:false, notes explaining the lock) — do NOT wait.
4. Implement the SMALLEST correct version of the feature that satisfies the issue's acceptance criteria. Follow existing patterns (resolveArtist/resolveAlbum cache-miss fallback, Log.app.notice over print, errorMessage + rollback for mutations). Do NOT invent scope beyond the issue. If the feature needs a core FFI that does not exist yet, and adding it is in scope, add it in \`core/\` AND regenerate the xcframework + \`lyrebird_core.swift\` bindings in the SAME commit (\`./macos/Scripts/build-core.sh --arm64-only\` then \`cd macos && rm -rf .build && swift build\`).
5. Build gates MUST pass before you push:
   - Rust touched: \`cargo fmt --all -- --check\`, \`cargo clippy --workspace --all-targets --all-features -- -D warnings\`, \`cargo test --workspace --exclude lyrebird-desktop --all-features --no-fail-fast\`.
   - Swift touched: \`cd macos && swift build\` (for FFI-adjacent, \`rm -rf macos/.build && swift build --package-path macos\`).
   Fix the underlying cause; never \`--no-verify\` / \`--no-gpg-sign\` (the user did not authorize bypassing signing).
6. Add a focused test only if it directly verifies the new behavior. No speculative tests/refactors/comments.
7. NO AI attribution anywhere — no \`Co-Authored-By\`, no mention of Claude/AI in commits, the PR, or comments. Author as the user. (Sub-agent commits get squash-merged under the user's signature.)
8. Open a PR: one sentence on the WHY, \`Closes #${item.issue}\`, and a \`pipeline:\` block (fixer-session, slice, hotspots-claimed, build-gate: pass, diff-stat). If you claimed a hotspot, name it so the reviewer releases it on merge.

Return the structured BUILD object. prOpened = the PR number, or null if you aborted (locked-out / out-of-scope / gate-unfixable).`
}

function reviewPrompt(pr, w) {
	const mergeLine = cfg.autoMerge
		? 'On `approve`: run `gh pr review --approve` THEN `gh pr merge ' + pr + ' --squash --auto --delete-branch` (auto-merge is ON for this run). If the PR claimed a hotspot, run `Scripts/area-lock.sh release <hotspot>` after queuing the merge.'
		: 'On `approve`: run `gh pr review --approve` only. Do NOT merge — the user merges manually. Still note the hotspot so it can be released on merge.'
	return `Review PR #${pr} adversarially. Wave ${w}. Follow .claude/agents/adversarial-reviewer.md EXACTLY.

Anti-anchoring: read the DIFF and its callers BEFORE the PR description / linked issue. Run the full 8-category rejection checklist (error-swallowing, MainActor-blocking FFI, paged-cache-only resolution, optimistic-UI-without-echo, hotspot growth, new-branch test coverage, speculative scope, banned-comments) — one finding each, "N/A because…" is valid, silence is not. Do the mandatory falsification step. Default outcome is request-changes; approve only if every category is N/A or addressed and scope is locked.

${mergeLine}

If you cannot form an independent verdict or the fixer-session equals your own, return outcome \`dispute-needs-opus\`. Return the structured REVIEW object.`
}

function disputePrompt(pr, w) {
	return `OPUS DISPUTE PASS for PR #${pr} (wave ${w}). The Sonnet first pass returned \`dispute-needs-opus\`. Follow the "Opus dispute pass" section of .claude/agents/adversarial-reviewer.md.

You MAY read the PR description and linked issue now (anchoring is no longer the failure mode; collusion is). Re-run the 8-category checklist. CHECK that Sonnet's findings were grounded (no false rejections) AND that any fixer pushback was not a deflection — either side can lose. You have final say.

${cfg.autoMerge ? 'If you approve: `gh pr review --approve` then `gh pr merge ' + pr + ' --squash --auto --delete-branch`, and release any claimed hotspot lock.' : 'If you approve: `gh pr review --approve` only (no merge; user merges manually).'} Return the structured REVIEW object.`
}

function refixPrompt(item, build, reviewNotes, w) {
	return `The adversarial reviewer requested changes on PR #${build.prOpened} (wave ${w}, issue #${item.issue}). Address EVERY finding below on the SAME branch (${build.branch || 'the existing fix/feat branch'}), keeping scope locked to the issue. Re-run the build gates. Push to the same branch (the existing PR updates). Do NOT open a new PR. No AI attribution. Ignore \`Scripts/wave-budget.sh\` (the orchestrator governs the budget — do not abort on it).

Reviewer findings:
${reviewNotes || '(see the PR review comment)'}

Return the structured BUILD object (prOpened = the same PR number).`
}

function releaseGatePrompt(w) {
	return `You are the M4 release-readiness gate for wave ${w}. Read-only verification — do NOT sign, notarize, or upload anything (that needs the user's Apple Developer credentials).

Verify and report one {name, pass, detail} per check:
1. macos/Scripts/{sign.sh, notarize.sh, make-dmg.sh, make-bundle.sh, generate-appcast.sh} exist and are non-trivial implementations (not stubs).
2. A release CI workflow exists under .github/workflows that wires build → sign → notarize → staple → DMG → appcast.
3. Hardened-runtime entitlements + Developer ID configuration are present in the macOS project.
4. POLISH_TARGETS.md: run each runnable \`check:\` line; report pass/fail.
5. \`gh release list\` / tags — is there release tooling/version wiring (Sparkle EdDSA appcast) in place?

Set \`releaseReady\` true only if a signed/notarized/stapled DMG could be produced by the user just by supplying credentials + running the scripts. List concrete \`blockers\` otherwise. Return the structured RELEASE_GATE object.`
}

function finalGatePrompt() {
	return `Final polish gate for the lyrebird-desktop finalization run. Read POLISH_TARGETS.md and run every runnable \`check:\` line. Also report: open priority:p0 count, open kind:bug count, open kind:feat count in milestone "${cfg.featMilestone}", and open fix/* PR count. \`polished\` = all runnable POLISH_TARGETS checks pass. Return the structured PREFLIGHT object.`
}

// ---------------------------------------------------------------------------
// REVIEW HELPERS
// ---------------------------------------------------------------------------
const refixAttempted = new Set()

async function reviewPR(pr, w) {
	if (!pr) return { pr: null, outcome: 'no-pr', notes: 'no PR to review' }
	let rev = await agent(reviewPrompt(pr, w), {
		agentType: 'adversarial-reviewer',
		isolation: 'worktree',
		phase: 'Review',
		schema: REVIEW_SCHEMA,
		label: `review:#${pr}`,
	})
	if (rev && rev.outcome === 'dispute-needs-opus') {
		rev = await agent(disputePrompt(pr, w), {
			agentType: 'adversarial-reviewer',
			model: 'opus',
			isolation: 'worktree',
			phase: 'Review',
			schema: REVIEW_SCHEMA,
			label: `dispute:#${pr}`,
		})
	}
	return rev || { pr, outcome: 'error', notes: 'reviewer returned null' }
}

// Build-stage callback's review side: review, and on request-changes do ONE in-wave refix.
async function reviewAndMaybeRefix(build, item, w) {
	if (!build) return { item, build: null, review: { outcome: 'error', notes: 'builder threw / returned null' } }
	if (!build.prOpened) return { item, build, review: { outcome: 'no-pr', notes: build.notes || 'no PR opened' } }

	let review = await reviewPR(build.prOpened, w)

	if (review && review.outcome === 'request-changes' && !refixAttempted.has(build.prOpened)) {
		refixAttempted.add(build.prOpened)
		const refixType = builderAgentType(item)
		const refixed = await agent(refixPrompt(item, build, review.notes, w), {
			agentType: refixType,
			isolation: 'worktree',
			phase: 'Build',
			schema: BUILD_SCHEMA,
			label: `refix:#${item.issue}`,
		})
		if (refixed && refixed.prOpened) {
			review = await reviewPR(refixed.prOpened, w)
			return { item, build: refixed, review }
		}
	}
	return { item, build, review }
}

// ---------------------------------------------------------------------------
// MAIN — the wave loop
// ---------------------------------------------------------------------------
log(
	`finalize-lyrebird-desktop | scope: bugs/polish${cfg.includeFeatures ? ' + features(M3)' : ''}${
		cfg.includeDist ? ' + M4 dist' : ''
	} | autoMerge: ${cfg.autoMerge} | wave cap: ${MAX_WAVES}${
		budget.total ? ` (budget ${Math.round(budget.total / 1000)}k tok)` : ' (no budget directive set — capped; pass args.maxWaves or a +Ntok directive to extend)'
	}`,
)

const run = {
	waves: [],
	issuesFiled: [],
	prsOpened: [],
	merged: [],
	unresolvedPRs: [],
	stoppedBecause: 'wave-cap',
}

let dryAuditRounds = 0

for (let w = 1; w <= MAX_WAVES; w++) {
	if (budget.total && budget.remaining() < WAVE_TOKEN_COST / 2) {
		run.stoppedBecause = 'budget-exhausted'
		log(`stopping before wave ${w}: ~${Math.round(budget.remaining() / 1000)}k tokens left, below half a wave.`)
		break
	}

	phase('Preflight')
	log(`── wave ${w}/${MAX_WAVES} ──`)
	const pre = await agent(preflightPrompt(w), {
		phase: 'Preflight',
		schema: PREFLIGHT_SCHEMA,
		label: `preflight:w${w}`,
	})

	// Polished + nothing actionable ⇒ done.
	const nothingActionable =
		(pre.openFeatM3 || 0) === 0 && (pre.openDist || 0) === 0 && (pre.openBugs || 0) === 0
	if (pre.polished && nothingActionable) {
		run.stoppedBecause = 'polished'
		run.waves.push({ wave: w, preflight: pre, note: 'polished + no actionable issues' })
		log(`wave ${w}: POLISH_TARGETS pass and no actionable issues. Pipeline idle — done.`)
		break
	}

	// Drain ceiling ⇒ review the open fix/* PRs once, then stop new work.
	if ((pre.openFixPRs || 0) >= DRAIN_CEILING) {
		log(`wave ${w}: drain ceiling hit (${pre.openFixPRs} open fix/* PRs). Reviewing them, then stopping new audit/fix.`)
		phase('Review')
		const drainPRs = pre.openFixPRNumbers || []
		const drained = await parallel(drainPRs.map((pr) => () => reviewPR(pr, w)))
		drained.filter(Boolean).forEach((r) => {
			if (r.outcome === 'approve') run.merged.push(r.pr)
			else if (r.pr) run.unresolvedPRs.push(r.pr)
		})
		run.waves.push({ wave: w, preflight: pre, drainReviewed: drainPRs })
		run.stoppedBecause = 'drain-ceiling'
		break
	}

	// ---- Audit (8 parallel auditors) ----
	phase('Audit')
	const audits = (
		await parallel(SLICES.map((s) => () => agent(auditPrompt(s, w), {
			agentType: 'area-auditor',
			phase: 'Audit',
			schema: AUDIT_SCHEMA,
			label: `audit:${s.replace('slice:', '')}:w${w}`,
		})))
	).filter(Boolean)

	const filed = audits.flatMap((a) => a.issueNumbers || [])
	const totalFiled = audits.reduce((n, a) => n + (a.issuesFiled || 0), 0)
	run.issuesFiled.push(...filed)
	const downgraded = audits.filter((a) => a.autoDowngrade).map((a) => a.slice)
	log(`wave ${w} audit: ${totalFiled} issue(s) filed across ${audits.length} slices${downgraded.length ? `; auto-downgraded: ${downgraded.join(', ')}` : ''}.`)

	if (downgraded.length) {
		log(`wave ${w}: auto-downgrade on ${downgraded.join(', ')} — surfaced, not filed. Continuing with feature/dist track only for these.`)
	}
	if (totalFiled > 10) {
		run.stoppedBecause = 'audit-overflow'
		run.waves.push({ wave: w, preflight: pre, audits, note: 'audit exceeded 10-finding ceiling' })
		log(`wave ${w}: audit produced ${totalFiled} findings (>10 ceiling). Halting for human review — likely a real regression cluster or noisy auditors.`)
		break
	}
	if (totalFiled === 0) dryAuditRounds++
	else dryAuditRounds = 0

	// ---- Triage (bug/polish manifest) ----
	phase('Triage')
	let manifest = []
	if (filed.length) {
		const triage = await agent(triagePrompt(w, filed), {
			agentType: 'problem-triager',
			phase: 'Triage',
			schema: TRIAGE_SCHEMA,
			label: `triage:w${w}`,
		})
		manifest = (triage.manifest || []).map((m) => ({
			issue: m.issue,
			slice: m.slice,
			hotspot: m.hotspot,
			priority: m.priority,
			kind: 'bug',
			builder: 'area-fixer',
			title: '',
		}))
		log(`wave ${w} triage: ${manifest.length} fix(es) in manifest, ${(triage.rejected || []).length} rejected.`)
	}

	// ---- Select feature + dist batches (independent of audit) ----
	phase('Select')
	let featItems = []
	let distItems = []
	if (cfg.includeFeatures && (pre.openFeatM3 || 0) > 0) {
		const sel = await agent(featSelectPrompt(w, cfg.featBatchPerWave, cfg.featMilestone), {
			phase: 'Select',
			schema: SELECT_SCHEMA,
			label: `select-feat:w${w}`,
		})
		featItems = (sel.items || []).map((it) => ({ ...it, kind: 'feat', builder: 'claude' }))
	}
	if (cfg.includeDist && (pre.openDist || 0) > 0) {
		const sel = await agent(distSelectPrompt(w, cfg.distBatchPerWave), {
			phase: 'Select',
			schema: SELECT_SCHEMA,
			label: `select-dist:w${w}`,
		})
		distItems = (sel.items || []).map((it) => ({ ...it, kind: it.kind || 'dist', builder: 'claude' }))
	}

	// Combine: bugs first (highest signal), then features, then dist. Enforce ≤1/hotspot + ceiling.
	const combined = [...manifest, ...featItems, ...distItems]
	const { selected: workItems, deferred } = pickWork(combined, cfg.buildCeiling)
	log(
		`wave ${w} work: ${workItems.length} item(s) [${workItems.map((i) => '#' + i.issue + '/' + i.kind).join(', ') || 'none'}]${
			deferred.length ? `; deferred ${deferred.length} (hotspot/ceiling)` : ''
		}.`,
	)

	if (workItems.length === 0) {
		run.waves.push({ wave: w, preflight: pre, audits, note: 'no actionable work this wave' })
		if (filed.length === 0 && dryAuditRounds >= 2) {
			run.stoppedBecause = 'idle'
			log(`wave ${w}: nothing to build and ${dryAuditRounds} dry audit rounds — pipeline idle. Done.`)
			break
		}
		continue
	}

	// ---- Build → Review pipeline (per item, no barrier) ----
	phase('Build')
	const results = await pipeline(
		workItems,
		(item) =>
			agent(item.builder === 'area-fixer' ? fixerPrompt(item, w) : featureBuilderPrompt(item, w), {
				agentType: builderAgentType(item),
				isolation: 'worktree',
				phase: 'Build',
				schema: BUILD_SCHEMA,
				label: `build:#${item.issue}/${item.kind}`,
			}),
		(build, item) => reviewAndMaybeRefix(build, item, w),
	)

	// Tally this wave.
	const waveOpened = []
	const waveMerged = []
	const waveUnresolved = []
	results.filter(Boolean).forEach((r) => {
		if (r.build && r.build.prOpened) waveOpened.push(r.build.prOpened)
		const o = r.review && r.review.outcome
		if (o === 'approve') waveMerged.push(r.build.prOpened)
		else if (r.build && r.build.prOpened) waveUnresolved.push(r.build.prOpened)
	})
	run.prsOpened.push(...waveOpened)
	run.merged.push(...waveMerged)
	run.unresolvedPRs.push(...waveUnresolved)
	log(`wave ${w} review: ${waveOpened.length} PR(s) opened, ${waveMerged.length} approved/auto-merge-queued, ${waveUnresolved.length} unresolved.`)

	// ---- M4 release-readiness gate ----
	let releaseGate = null
	if (cfg.includeDist) {
		phase('Release gate')
		releaseGate = await agent(releaseGatePrompt(w), {
			phase: 'Release gate',
			schema: RELEASE_GATE_SCHEMA,
			label: `release-gate:w${w}`,
		})
		log(`wave ${w} release gate: releaseReady=${releaseGate.releaseReady}${releaseGate.blockers && releaseGate.blockers.length ? `; blockers: ${releaseGate.blockers.length}` : ''}.`)
	}

	run.waves.push({
		wave: w,
		preflight: pre,
		filed,
		manifest: manifest.map((m) => m.issue),
		featSelected: featItems.map((i) => i.issue),
		distSelected: distItems.map((i) => i.issue),
		opened: waveOpened,
		merged: waveMerged,
		unresolved: waveUnresolved,
		releaseGate,
	})
}

// ---------------------------------------------------------------------------
// FINAL REPORT
// ---------------------------------------------------------------------------
phase('Report')
const finalGate = await agent(finalGatePrompt(), {
	phase: 'Report',
	schema: PREFLIGHT_SCHEMA,
	label: 'final-polish-gate',
})

const dedupe = (a) => Array.from(new Set(a))
const summary = {
	stoppedBecause: run.stoppedBecause,
	wavesRun: run.waves.length,
	issuesFiled: dedupe(run.issuesFiled),
	prsOpened: dedupe(run.prsOpened),
	mergedOrQueued: dedupe(run.merged),
	unresolvedPRs: dedupe(run.unresolvedPRs).filter((p) => !run.merged.includes(p)),
	finalPolished: finalGate.polished,
	finalPolishChecks: finalGate.polishChecks || [],
	openP0: finalGate.openP0,
	openBugs: finalGate.openBugs,
	openFeatM3: finalGate.openFeatM3,
	openFixPRs: finalGate.openFixPRs,
}

log(
	`DONE — stopped: ${summary.stoppedBecause} | waves: ${summary.wavesRun} | filed: ${summary.issuesFiled.length} | PRs opened: ${summary.prsOpened.length} | merged/queued: ${summary.mergedOrQueued.length} | unresolved: ${summary.unresolvedPRs.length} | polished: ${summary.finalPolished}`,
)

return summary
