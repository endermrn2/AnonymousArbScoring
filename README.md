# Anonymous P2P Arbitration Scoring

Trust without history: anyone can submit an **encrypted score (0..100)** for a target address; the contract stores **only the encrypted sum** and a **plain submission counter**. No rater identities or score history are kept. The DAO/owner uploads tier thresholds **in ciphertext** (Bronze/Silver/Gold). Verdicts are computed homomorphically and can be revealed **privately (user‑decrypt)** or **publicly (public‑decrypt)**.


Arbitration marketplaces and P2P platforms need **reputation**, but score histories leak sensitive information. This dApp provides **aggregate trust** (tier 0..3) with no ability to reconstruct who rated whom or with which value.

---

## Core Features

* **Encrypted scoring (0..100)** — any wallet can rate any target; only the aggregate is stored.
* **Anonymous by design** — no rater list, no per‑submission storage.
* **Encrypted policy** — owner uploads tier thresholds (Bronze, Silver, Gold) as ciphertexts.
* **Tier verdicts without division** — compares `sum ≥ threshold * count`; works fully under FHE.
* **Two reveal paths**:

  * **Private** verdict (decryptable only by the caller via EIP‑712 `userDecrypt`).
  * **Public** verdict (globally decryptable via `publicDecrypt`).
* **Publish aggregated sum** — optional public decrypt of the encrypted sum for off‑chain average (`sum_dec / count`).

---

## Frontend (what’s included)

Single‑file app with a clean two‑panel UI:

* **Submit Encrypted Score** — input `target` + `score`, Relayer encrypts locally, sends proof + handles.
* **Aggregate** — get `(sumHandle, count)`, publish sum, decrypt sum, compute average client‑side.
* **Policy (Owner)** — set encrypted thresholds, make policy public (for audits), transfer ownership.
* **Verdict** — request tier **Private** (user‑decrypt) or **Public** (public‑decrypt).

The page automatically shows the current **Owner** and disables owner‑only buttons if you’re not the owner.

---

## Usage Walkthrough

### A) Anyone — submit a score

1. **Connect** wallet.
2. In **Submit Encrypted Score**: enter `Target Address` and `Score (0..100)`.
3. Click **Submit Score (encrypted)**.

   * The SDK encrypts locally, produces handles + proof.
   * The contract updates `sum` (encrypted) and `count` (plain).

### B) Owner — set encrypted policy

1. Connect **as contract owner** (top right shows owner; “Owner detected ✓” means you’re set).
2. Enter **Bronze / Silver / Gold** thresholds (0..100).
3. Click **Set Encrypted**.

   * If your RPC fails to estimate gas on FHE calls, the frontend retries with a manual `gasLimit`.
4. (Optional) **Make Policy Public** — marks thresholds as publicly decryptable for audits.

### C) Aggregate — public sum & off‑chain average

1. In **Aggregate**, click **Get Handles** to see `sum` handle and `count`.
2. Click **Publish Sum** to mark the encrypted sum as publicly decryptable.
3. Click **Decrypt Sum** to fetch the public value; average is shown as `sum_dec / count`.

### D) Verdict — private or public

* **Private**: click **Private** → the app signs an EIP‑712 message and calls `userDecrypt` → only you see the tier (0=None, 1=Bronze, 2=Silver, 3=Gold).
* **Public**: click **Public** → the contract marks the verdict ciphertext public → anyone can `publicDecrypt` it.

---


---

## License

