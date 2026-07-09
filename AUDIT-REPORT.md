# 🔐 Security Review — Tachyon-Account

Multi-agent audit (12 parallel attacker agents, pashov `solidity-auditor` v3, Opus) plus a manual pass with the `solidity-security` and `solidity-gas-optimization` reference skills.

---

## Scope

|                                  |                                                                             |
| -------------------------------- | --------------------------------------------------------------------------- |
| **Mode**                         | Default (all in-scope `.sol`)                                               |
| **Files reviewed**               | `src/TachyonPaymaster.sol` · `src/TachyonAccount.sol`                        |
| **Branch**                       | `feat/add-depositFor` (includes `depositFor`)                               |
| **Confidence threshold**         | 80                                                                          |

> Note: the audit bundle was built from the worktree base (pre-`depositFor`); analysis and every trace below were re-verified against the actual branch source that includes `depositFor`.

---

## Findings

### [92] 1. `rescueAccount` drains the shared pool — no balance cap, no ledger decrement

`TachyonPaymaster.rescueAccount` · Confidence: 92

**Description**
`rescueAccount` transfers an arbitrary `amount` of a token out of the pooled contract once *any* named user is closed, but it never checks `amount <= balances[user][token]` and never decrements `balances`, so it draws from tokens backing *other* users' balances and leaves the rescued user's ledger entry intact (enabling a second withdrawal). `chargeAccount` (lines 168-182) does both checks correctly; `rescueAccount` (lines 185-204) does neither.

**Proof**
Alice `deposit(USDC, 1000)`, Bob `deposit(USDC, 1000)` → pool = 2000. Bob self-closes (request → 7 days → `closeAccount`; `balances[Bob][USDC]` stays 1000). Foundation calls `rescueAccount(Bob, USDC, 2000)`: the guard `!isClosed && token != address(0)` is `false` (Bob is closed) so it passes, and `safeTransfer(USDC, RathFoundation, 2000)` empties the pool. `balances[Alice][USDC]` still reads 1000 but the pool holds 0 → Alice's `withdraw`/`chargeAccount` revert forever. The closed-account precondition is self-service (any address can close its own account), and the drained funds belong to a *different* user, so this exceeds "admin can rug."

**Fix**

```diff
     } else {
-        SafeTransferLib.safeTransfer(token, RathFoundation, amount);
+        // Rescue only the closed user's own tracked balance; never the shared pool.
+        uint256 bal = balances[user][token];
+        if (amount > bal) revert InsufficientBalance();
+        balances[user][token] = bal - amount;
+        SafeTransferLib.safeTransfer(token, RathFoundation, amount);
     }
```

---

### [82] 2. `deposit` / `depositFor` credit the requested amount, not the amount received

`TachyonPaymaster.deposit` · `TachyonPaymaster.depositFor` · Confidence: 82

**Description**
Both credit `balances[...][token] += amount` (the requested value), not the delta actually received. For a fee-on-transfer or negatively-rebasing token the pool receives less than `amount`, so the sum of per-user balances exceeds the real pool and the last user(s) to withdraw or be charged are permanently short — cross-user loss because balances share one pool.

**Proof**
10%-fee token: Alice `deposit(FEE, 100)` → pool receives 90, `balances[Alice][FEE] = 100`. Bob same → pool 180, ledger sum 200. `chargeAccount(Alice, FEE, 100)` sends 100 out → pool 80. Bob `withdraw(FEE)` calls `safeTransfer(FEE, Bob, 100)` against an 80-token pool → reverts (`TransferFailed`). Bob's 100 is unrecoverable; no outbound path pays him.

**Fix**

```diff
-        SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
-        balances[msg.sender][token] += amount;
+        uint256 pre = ERC20(token).balanceOf(address(this));
+        SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
+        uint256 received = ERC20(token).balanceOf(address(this)) - pre;
+        balances[msg.sender][token] += received;
```

(Apply the same measure-the-delta pattern in `depositFor`. Alternatively, document and enforce a standard-ERC20-only allowlist.)

---

## Findings List

| # | Confidence | Title |
|---|------------|-------|
| 1 | [92] | `rescueAccount` drains the shared pool (no cap, no decrement) |
| 2 | [82] | `deposit`/`depositFor` credit requested, not received, amount |

---

## Leads

_Vulnerability trails with concrete code smells; not scored._

- **Unconditional ETH rescue** — `TachyonPaymaster.rescueAccount` — Code smells: the `token == address(0)` branch bypasses the closed-account guard entirely (`&& token != address(0)` short-circuits) and there is no per-user ETH accounting, so the Foundation can sweep all contract ETH at any time for any `user`. Likely intended as stray-ETH recovery, but the `user` parameter implies a per-user authorization that does not exist. Consider a dedicated `rescueETH(amount)` instead.
- **Charge evasion via closure** — `TachyonPaymaster.chargeAccount` / `closeAccount` — Code smells: `chargeAccount` is gated by `onlyOpenAccount(user)`, while `withdraw` after close is unconditional. A user who owes off-chain-accrued fees can `submitAccountClosureRequest` → wait the 7-day cooling window → `closeAccount` → `withdraw` everything, permanently blocking settlement. The cooling period is the intended defense; exploitability depends on whether settlement latency can exceed 7 days. Same shape exists in `TachyonAccount`.
- **Bundle-hash replay** — `TachyonPaymaster.chargeAccount` — Code smells: `bundleRootHash` is only emitted, never recorded or checked, so the same bundle can be charged repeatedly up to the user's balance. Foundation-gated, so an integrity gap rather than an external exploit.
- **`depositFor` does not check the caller's own account state** — `TachyonPaymaster.depositFor` — Code smells: gates only on `onlyOpenAccount(user)` (the target), not the payer. A payer whose own account is closed can still originate deposits. Traced to no fund loss; behavior-only, flagged against off-chain assumptions.
- **`payable` `deposit` traps ETH** — `TachyonAccount.deposit` — Code smells: declared `payable` but never reads `msg.value`; any ETH sent alongside a deposit is stranded, recoverable only by the Foundation via `rescueAccount` after closure. Remove `payable` unless ETH deposits are intended.
- **Unbounded charge/rescue in single-user account** — `TachyonAccount.chargeAccount` / `rescueAccount` — Code smells: same missing-cap pattern as the Paymaster, but single-user so it is self-contained (only the one owner's funds), not cross-user theft. Worth a one-line consistency fix.

---

## Gas Optimization Notes (`solidity-gas-optimization` skill)

Low-risk, non-behavioral. None are required for correctness.

- **Struct packing — `UserAccount`.** Fields are `bool isClosureRequested; uint256 closureRequestTime; bool isClosed;` → 3 storage slots (the `uint256` between the two bools forces each bool into its own slot). Reorder to `uint256 closureRequestTime; bool isClosureRequested; bool isClosed;` so the two bools share one slot → 2 slots total. Saves one `SSTORE` on the first write per account.
- **Cache `userAccounts[msg.sender]` / `balances[...]`.** Several functions read the same mapping slot 2–3× (e.g. `closeAccount` reads `account.isClosureRequested` then `account.closureRequestTime`). Already partly done via `storage` refs — confirm each hot path caches into memory where the value is read more than once.
- **`version()` returns a `string`.** Constant `"0.0.1"`; fine as-is, but a `bytes32` constant would be cheaper if ever called on-chain (it isn't, so ignore).
- **Custom errors / immutables / constants** are already used well (`RathFoundation` immutable, `COOLING_PERIOD` constant, custom errors throughout) — consistent with the skill's high-priority recommendations. No `require`-string waste found.
- **Redundant guard** — `TachyonAccount.chargeAccount` repeats `if (msg.sender != RathFoundation)` inside a function already carrying the `onlyRathFoundation` modifier. Dead code; remove it (tiny deploy + runtime saving, and clarity).

---

> ⚠️ This review was performed with AI assistance. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. A professional human audit and a bug bounty are strongly recommended before mainnet deployment.
