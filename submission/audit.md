```json
{
  "vulnerabilities": [
    {
      "title": "rescueAccount does not decrement the user ledger, enabling an unprivileged double-withdrawal that drains other users' pooled deposits",
      "severity": "high",
      "summary": "`TachyonPaymaster.rescueAccount` transfers a closed user's tokens out of the shared pool but never zeroes `balances[user][token]`. Because the paymaster commingles all users' deposits of a token in a single pool while tracking balances per user, the still-credited (phantom) balance lets the user call `withdraw` and be paid a second time from the pool, i.e. from other users' funds.",
      "description": [
        {
          "file": "src/TachyonPaymaster.sol",
          "line_start": 181,
          "line_end": 196,
          "desc": "`rescueAccount` sends `amount` of `token` from the contract to `RathFoundation` when `userAccounts[user].isClosed` is true, but it **never updates `balances[user][token]`**. Contrast this with `withdraw` (line 119) and `chargeAccount` (line 174), the two other outbound-token paths, which both decrement the ledger before/around the transfer. Rescuing a closed account's tracked balance — the operation the NatSpec on line 182 (\"Rescues tokens from a closed account\") describes — therefore removes the tokens from the pool while leaving the user's `balances[user][token]` entry fully intact."
        },
        {
          "file": "src/TachyonPaymaster.sol",
          "line_start": 107,
          "line_end": 123,
          "desc": "`withdraw` only requires `account.isClosed` and pays out the current `balances[msg.sender][token]` from the shared pool, then zeroes it. Since `rescueAccount` left the balance non-zero, the closed user can call `withdraw` after a rescue and receive the same amount **again**, this time drawn from the tokens backing other users' balances. The `sum(balances[*][token]) == token.balanceOf(this)` solvency invariant is broken and other users' withdrawals subsequently revert (`SafeTransferLib.safeTransfer` on an empty pool)."
        }
      ],
      "impact": "Direct, permanent loss of user funds. After the Foundation performs an ordinary (non-malicious) rescue of a closed account's balance, that user retains a phantom ledger balance and can withdraw it a second time, transferring other users' deposits of the same token to themselves. The victims' `balances` still read their full amount but the pool no longer holds enough tokens to satisfy them, so their `withdraw`/`chargeAccount` calls revert forever. The closure precondition is self-service (any address can close its own account), and the exploiting `withdraw` call is unprivileged — no malicious privileged action is needed, only a routine rescue followed by a normal withdrawal.",
      "proof_of_concept": "1. Alice `deposit(USDC, 1000)` and Bob `deposit(USDC, 1000)` → `balances[Alice][USDC]=balances[Bob][USDC]=1000`, pool = 2000.\n2. Alice `submitAccountClosureRequest()`, waits 7 days, `closeAccount()`. `balances[Alice][USDC]` is still 1000.\n3. Foundation performs the intended rescue of Alice's balance: `rescueAccount(Alice, USDC, 1000)`. Pool = 1000, 1000 USDC sent to RathFoundation, but `balances[Alice][USDC]` is **still 1000** (never decremented).\n4. Alice calls `withdraw(USDC)`: reads `balances[Alice][USDC]=1000`, zeroes it, and `safeTransfer`s 1000 USDC to Alice from the pool. Pool = 0.\n5. Bob closes and calls `withdraw(USDC)`: the pool is empty, so `SafeTransferLib.safeTransfer` reverts. Bob's 1000 USDC is permanently lost.\nThe same 1000 accounting-USDC left the contract twice (once to the Foundation, once to Alice), and the shortfall is stolen from Bob. A concrete failing/pinning test for this exact sequence exists at `test/TachyonPaymaster.t.sol::testRescueAccountCanDrainOtherUsersPool_AuditFinding`.",
      "remediation": "In the ERC20 branch of `rescueAccount`, bound the rescue to and decrement the user's own tracked balance before transferring, mirroring `withdraw`/`chargeAccount`:\n    } else {\n        uint256 bal = balances[user][token];\n        if (amount > bal) revert InsufficientBalance();\n        balances[user][token] = bal - amount;\n        SafeTransferLib.safeTransfer(token, RathFoundation, amount);\n    }\nThis keeps the per-user ledger consistent with the pooled token balance and makes a subsequent `withdraw` impossible for the already-rescued amount. Consider also splitting stray-asset recovery into a separate function that can only ever move the surplus (`token.balanceOf(this) - trackedTotal`)."
    },
    {
      "title": "deposit and depositFor credit the requested amount instead of the amount actually received, breaking pool solvency for fee-on-transfer or rebasing tokens",
      "severity": "high",
      "summary": "`TachyonPaymaster.deposit` and `depositFor` credit `balances[...][token] += amount` using the caller-requested `amount`, not the number of tokens the contract actually received. The contract accepts arbitrary token addresses with no allowlist, so a fee-on-transfer or negatively-rebasing token deposits fewer tokens than credited, making the sum of per-user ledger balances exceed the real pooled balance and permanently trapping or misallocating user funds.",
      "description": [
        {
          "file": "src/TachyonPaymaster.sol",
          "line_start": 126,
          "line_end": 138,
          "desc": "`deposit` calls `SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount)` (line 134) and then unconditionally credits `balances[msg.sender][token] += amount` (line 135). For a fee-on-transfer or deflationary token the contract receives strictly less than `amount`, but the ledger is credited the full `amount`. `token` is an arbitrary caller-supplied address (only `address(0)` and a zero amount are rejected on lines 127-132), so nothing restricts the deposited asset to a standard ERC20."
        },
        {
          "file": "src/TachyonPaymaster.sol",
          "line_start": 141,
          "line_end": 156,
          "desc": "`depositFor` has the identical defect on line 153 (`balances[user][token] += amount`) after the transfer on line 152, over-crediting the target user's balance by the fee amount."
        },
        {
          "file": "src/TachyonPaymaster.sol",
          "line_start": 107,
          "line_end": 123,
          "desc": "`withdraw` pays out the (over-credited) `balances[msg.sender][token]` from the shared pool. Once the summed ledger exceeds the real pool balance, `SafeTransferLib.safeTransfer` reverts for the last claimant, or earlier claimants drain the shortfall from later ones."
        }
      ],
      "impact": "Loss of user funds without any privileged action. Because balances are pooled per token, over-crediting one deposit makes the pool insolvent versus the summed ledger. Concretely, even a single user who deposits a 10%-fee token has `balances=100e6` while the pool holds only `90e6`; their `withdraw` attempts to send 100e6 from a 90e6 pool and reverts, permanently locking the 90e6 they did deliver. With multiple users, the first to withdraw is paid in full and the last user's tokens are stolen to cover the accumulated fee shortfall. Rebasing tokens (negative rebase) produce the identical insolvency.",
      "proof_of_concept": "10%-fee-on-transfer token FEE:\n1. Alice `deposit(FEE, 100)` → contract receives 90, `balances[Alice][FEE]=100`. Pool = 90.\n2. Bob `deposit(FEE, 100)` → contract receives 90, `balances[Bob][FEE]=100`. Pool = 180, ledger sum = 200.\n3. `chargeAccount(Alice, FEE, 100)` sends 100 out → pool = 80.\n4. Bob closes and calls `withdraw(FEE)`: `safeTransfer(FEE, Bob, 100)` against an 80-token pool → reverts (`TransferFailed`). Bob's funds are unrecoverable; no outbound path can pay him.\nEven with a single depositor the over-credit locks funds: pool holds 90, ledger says 100, and `withdraw` reverts trying to send 100. A pinning test for this exact behavior exists at `test/TachyonPaymaster.t.sol::testDepositOverCreditsFeeOnTransferToken_AuditFinding`.",
      "remediation": "Credit the measured received delta rather than the requested amount, in both `deposit` and `depositFor`:\n    uint256 pre = ERC20(token).balanceOf(address(this));\n    SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);\n    uint256 received = ERC20(token).balanceOf(address(this)) - pre;\n    balances[user][token] += received;\nAlternatively, enforce a strict allowlist of standard, non-fee, non-rebasing ERC20 tokens and reject all others at deposit time, and document the exclusion explicitly."
    }
  ]
}
```
