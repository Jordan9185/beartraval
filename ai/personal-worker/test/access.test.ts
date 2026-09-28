import assert from "node:assert/strict";
import test from "node:test";
import { personalAIUsers, personalAIClaimOrder } from "../../../supabase/functions/_shared/personal-ai-access.ts";

const first = "00000000-0000-0000-0000-00000000000a";
const second = "00000000-0000-0000-0000-00000000000b";
const outsider = "00000000-0000-0000-0000-00000000000c";

test("允許多個指定帳號，不自動放行其他帳號", () => {
  const users = personalAIUsers(` ${first.toUpperCase()}, ${second}, ${first}`);
  assert.deepEqual(users, [first, second]);
  assert.equal(users.includes(outsider), false);
});

test("新名單取代舊設定，空白與錯誤設定不退回舊帳號", () => {
  assert.deepEqual(personalAIUsers(undefined, first), [first]);
  assert.deepEqual(personalAIUsers(second, first), [second]);
  for (const value of ["", " ", `${first},`, `${first},wawabear`, "*"]) {
    assert.deepEqual(personalAIUsers(value, first), []);
  }
  assert.deepEqual(personalAIUsers(undefined), []);
});

test("依等待時間選帳號，第二個使用者不必等第一個清空所有工作", () => {
  assert.deepEqual(personalAIClaimOrder([first, second], [{ owner_id: second }, { owner_id: first }]), [second, first]);
  assert.deepEqual(personalAIClaimOrder([first, second], [{ owner_id: outsider }, { owner_id: second }, { owner_id: second }]), [second, first]);
  assert.deepEqual(personalAIClaimOrder([first, second], []), [first, second]);
});
