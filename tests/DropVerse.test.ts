
import { beforeEach, describe, expect, it } from "vitest";
import { Cl } from "@stacks/transactions";

const CONTRACT = "DropVerse";
const MANIFEST = "Clarinet.toml";

let owner!: string;
let alice!: string;

const emptyProof = Cl.list([]);

const toBuff32 = (data: Buffer) => Cl.buffer(new Uint8Array(data));

function makeLeaf(address: string, amount: bigint | number) {
  const snippet = `(sha256 (concat (hash160 (unwrap! (to-consensus-buff? '${address}) 0x00)) (sha256 (unwrap! (to-consensus-buff? u${amount.toString()}) 0x00))))`;
  const { result } = simnet.execute(snippet);
  return Buffer.from((result as any).value, "hex");
}

function initOwner() {
  const call = simnet.callPublicFn(CONTRACT, "initialize-owner", [], owner);
  expect(call.result).toBeOk(Cl.bool(true));
}

function scheduleAirdrop(
  id: bigint,
  root: Buffer,
  total: bigint,
  start: bigint,
  end: bigint,
) {
  const call = simnet.callPublicFn(
    CONTRACT,
    "schedule-airdrop",
    [Cl.uint(id), toBuff32(root), Cl.uint(total), Cl.uint(start), Cl.uint(end)],
    owner,
  );
  expect(call.result).toBeOk(Cl.bool(true));
}

function fund(amount: bigint) {
  const call = simnet.callPublicFn(CONTRACT, "fund-contract", [Cl.uint(amount)], owner);
  expect(call.result).toBeOk(Cl.bool(true));
}

function getContractBalance() {
  return simnet.callReadOnlyFn(CONTRACT, "get-contract-balance", [], owner).result;
}

beforeEach(async () => {
  await simnet.initSession(process.cwd(), MANIFEST);
  const accounts = simnet.getAccounts();
  owner = accounts.get("wallet_1")!;
  alice = accounts.get("wallet_2")!;
});

describe("DropVerse airdrop", () => {
  it("initializes owner only once", () => {
    initOwner();

    const secondInit = simnet.callPublicFn(CONTRACT, "initialize-owner", [], owner);
    expect(secondInit.result).toBeErr(Cl.uint(110));
  });

  it("allows a funded airdrop claim and tracks counts", () => {
    initOwner();

    const start = BigInt(simnet.blockHeight);
    const end = start + 10n;
    const airdropId = 1n;
    const amount = 500n;
    const root = makeLeaf(alice, amount);

    scheduleAirdrop(airdropId, root, amount, start, end);
    fund(amount);

    const claim = simnet.callPublicFn(
      CONTRACT,
      "claim",
      [Cl.uint(airdropId), emptyProof, Cl.uint(amount)],
      alice,
    );
    expect(claim.result).toBeOk(Cl.bool(true));

    const claimed = simnet.callReadOnlyFn(
      CONTRACT,
      "has-claimed",
      [Cl.uint(airdropId), Cl.principal(alice)],
      alice,
    );
    expect(claimed.result).toBeBool(true);

    const totalClaims = simnet.callReadOnlyFn(
      CONTRACT,
      "get-total-claims",
      [Cl.uint(airdropId)],
      alice,
    );
    expect(totalClaims.result).toBeUint(1n);

    const contractBalance = getContractBalance();
    expect(contractBalance).toBeUint(0n);
  });

  it("rejects double claims for the same address", () => {
    initOwner();

    const start = BigInt(simnet.blockHeight);
    const end = start + 5n;
    const airdropId = 2n;
    const amount = 250n;
    const root = makeLeaf(alice, amount);

    scheduleAirdrop(airdropId, root, amount, start, end);
    fund(amount);

    const firstClaim = simnet.callPublicFn(
      CONTRACT,
      "claim",
      [Cl.uint(airdropId), emptyProof, Cl.uint(amount)],
      alice,
    );
    expect(firstClaim.result).toBeOk(Cl.bool(true));

    const secondClaim = simnet.callPublicFn(
      CONTRACT,
      "claim",
      [Cl.uint(airdropId), emptyProof, Cl.uint(amount)],
      alice,
    );
    expect(secondClaim.result).toBeErr(Cl.uint(103));
  });

  it("fails a claim with an invalid proof/amount", () => {
    initOwner();

    const start = BigInt(simnet.blockHeight);
    const end = start + 5n;
    const airdropId = 3n;
    const validAmount = 300n;
    const wrongAmount = 400n;
    const root = makeLeaf(alice, validAmount);

    scheduleAirdrop(airdropId, root, validAmount, start, end);
    fund(validAmount);

    const badClaim = simnet.callPublicFn(
      CONTRACT,
      "claim",
      [Cl.uint(airdropId), emptyProof, Cl.uint(wrongAmount)],
      alice,
    );
    expect(badClaim.result).toBeErr(Cl.uint(104));
  });

  it("finalizes after the window, refunds unclaimed, and blocks further claims", () => {
    initOwner();

    const start = BigInt(simnet.blockHeight);
    const end = start + 5n;
    const airdropId = 4n;
    const claimAmount = 200n;
    const total = 1000n;
    const root = makeLeaf(alice, claimAmount);

    scheduleAirdrop(airdropId, root, total, start, end);
    fund(total);

    const claim = simnet.callPublicFn(
      CONTRACT,
      "claim",
      [Cl.uint(airdropId), emptyProof, Cl.uint(claimAmount)],
      alice,
    );
    expect(claim.result).toBeOk(Cl.bool(true));

    const balanceAfterClaim = getContractBalance();
    expect(balanceAfterClaim).toBeUint(total - claimAmount);

    while (BigInt(simnet.blockHeight) <= end) {
      simnet.mineBlock([]);
    }

    const finalize = simnet.callPublicFn(
      CONTRACT,
      "finalize-airdrop",
      [Cl.uint(airdropId)],
      owner,
    );
    expect(finalize.result).toBeOk(Cl.bool(true));

    const info = simnet.callReadOnlyFn(CONTRACT, "get-airdrop-info", [Cl.uint(airdropId)], owner);
    const someInfo = info.result as any;
    expect(someInfo.type).toBe("some");
    const infoTuple = someInfo.value as any;
    const finalizedFlag = infoTuple.value.finalized;
    expect(finalizedFlag).toBeBool(true);

    const balanceAfterFinalize = getContractBalance();
    expect(balanceAfterFinalize).toBeUint(0n);

    const postFinalizeClaim = simnet.callPublicFn(
      CONTRACT,
      "claim",
      [Cl.uint(airdropId), emptyProof, Cl.uint(claimAmount)],
      alice,
    );
    expect(postFinalizeClaim.result).toBeErr(Cl.uint(101));
  });
});
