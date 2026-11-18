/**
 * Two-account friend feature smoke test against a running server.
 *
 * Terminal 1:
 *   PORT=3569 DATA_DIR=../.tools/social-smoke-data ENCOUNTER_RATE=0 npm start
 * Terminal 2:
 *   SMOKE_URL=ws://127.0.0.1:3569 npm run smoke:social
 */
import assert from "node:assert/strict";
import WebSocket from "ws";

type Dict = Record<string, any>;
type Predicate = (message: Dict) => boolean;

const URL = process.env.SMOKE_URL ?? "ws://127.0.0.1:3569";

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

class Client {
  private ws!: WebSocket;
  private queue: Dict[] = [];
  private waiters: Array<{
    types: string[];
    predicate: Predicate;
    resolve: (message: Dict) => void;
    timer: ReturnType<typeof setTimeout>;
  }> = [];
  public readonly name: string;

  constructor(name: string) {
    this.name = name;
  }

  open(): Promise<void> {
    this.ws = new WebSocket(URL);
    this.ws.on("message", (data) => this.onMessage(data.toString()));
    return new Promise((resolve, reject) => {
      // A localhost handshake can finish before the listener is attached, so
      // check the ready state as well as waiting for the open event.
      if (this.ws.readyState === WebSocket.OPEN) {
        resolve();
        return;
      }
      if (this.ws.readyState === WebSocket.CLOSING || this.ws.readyState === WebSocket.CLOSED) {
        reject(new Error(`${this.name}: socket closed before open`));
        return;
      }
      const timer = setTimeout(() => reject(new Error(`${this.name}: open timeout`)), 5000);
      this.ws.once("open", () => {
        clearTimeout(timer);
        resolve();
      });
      this.ws.once("error", (error) => {
        clearTimeout(timer);
        reject(error);
      });
    });
  }

  private onMessage(raw: string): void {
    let message: Dict;
    try {
      message = JSON.parse(raw);
    } catch {
      return;
    }
    const index = this.waiters.findIndex(
      (waiter) => waiter.types.includes(message.type) && waiter.predicate(message)
    );
    if (index >= 0) {
      const [waiter] = this.waiters.splice(index, 1);
      clearTimeout(waiter.timer);
      waiter.resolve(message);
      return;
    }
    if (message.type !== "hello" && message.type !== "pong") this.queue.push(message);
  }

  waitFor(type: string, predicate: Predicate = () => true, timeout = 5000): Promise<Dict> {
    const index = this.queue.findIndex(
      (message) => message.type === type && predicate(message)
    );
    if (index >= 0) {
      const [message] = this.queue.splice(index, 1);
      return Promise.resolve(message);
    }
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        const pending = this.waiters.find((waiter) => waiter.timer === timer);
        if (pending) this.waiters.splice(this.waiters.indexOf(pending), 1);
        reject(new Error(`${this.name}: timed out waiting for ${type}`));
      }, timeout);
      this.waiters.push({ types: [type], predicate, resolve, timer });
    });
  }

  /** Drop queued messages of one type before an action that will produce a fresh one. */
  drain(type: string): void {
    this.queue = this.queue.filter((message) => message.type !== type);
  }

  send(message: Dict): void {
    this.ws.send(JSON.stringify(message));
  }

  close(): void {
    this.ws.close();
  }
}

function friendNames(state: Dict): string[] {
  return (state.friends as Dict[]).map((friend) => friend.name).sort();
}

function incomingNames(state: Dict): string[] {
  return (state.incomingRequests as Dict[]).map((request) => request.name).sort();
}

function outgoingNames(state: Dict): string[] {
  return (state.outgoingRequests as Dict[]).map((request) => request.name).sort();
}

const suffix = Math.random().toString(36).slice(2, 8).toUpperCase();
const password = "smoke123";
const accountA = `FriendA${suffix}`;
const accountB = `FriendB${suffix}`;
const nameA = `Mira${suffix}`;
const nameB = `Theo${suffix}`;

async function register(
  client: Client,
  username: string,
  characterName: string,
  color: string,
  starter: string
): Promise<{ token: string; characterId: string }> {
  client.send({ type: "register", username, password });
  const auth = await client.waitFor("auth_ok");
  assert.equal(auth.character, null, `${client.name}: new account should have no character`);
  client.send({ type: "create_character", name: characterName, color, starter });
  const created = await client.waitFor("character_created");
  const state = await client.waitFor("map_state");
  assert.equal(state.self.name, characterName);
  return { token: auth.token as string, characterId: created.character.id as string };
}

async function social(client: Client, predicate: Predicate = () => true) {
  client.drain("social_state");
  client.send({ type: "social_state" });
  return client.waitFor("social_state", predicate);
}

async function main(): Promise<void> {
  console.log(`Social smoke testing ${URL} (suffix ${suffix})`);
  const a = new Client("A");
  const b = new Client("B");
  await a.open();
  const idsA = await register(a, accountA, nameA, "#e76f51", "snivy");
  await b.open();
  const idsB = await register(b, accountB, nameB, "#2a9d8f", "tepig");
  await a.waitFor(
    "player_joined",
    (message) => message.player?.id === idsB.characterId
  );
  // World entry sends an automatic snapshot before the other player exists.
  // Consume those so later assertions only see responses to fresh requests.
  await a.waitFor("social_state");
  await b.waitFor("social_state");
  console.log("  [ok] two accounts registered and entered the world");

  const stateA = await social(
    a,
    (message) =>
      (message.nearby as Dict[]).some((row) => row.id === idsB.characterId)
  );
  const stateB = await social(
    b,
    (message) =>
      (message.nearby as Dict[]).some((row) => row.id === idsA.characterId)
  );
  const nearbyA = (stateA.nearby as Dict[]).find((row) => row.id === idsB.characterId);
  const nearbyB = (stateB.nearby as Dict[]).find((row) => row.id === idsA.characterId);
  assert.equal(nearbyA?.name, nameB);
  assert.equal(nearbyB?.name, nameA);
  assert.equal(nearbyA?.friend, false);
  assert.equal(nearbyB?.friend, false);
  console.log("  [ok] both clients see each other as nearby trainers");

  a.drain("social_state");
  b.drain("social_state");
  a.send({ type: "friend_request", playerId: idsB.characterId });
  const outgoingA = await a.waitFor(
    "social_state",
    (message) => (message.outgoingRequests as Dict[]).length === 1
  );
  assert.deepEqual(outgoingNames(outgoingA), [nameB]);
  const incomingB = await b.waitFor(
    "social_state",
    (message) => (message.incomingRequests as Dict[]).length === 1
  );
  assert.deepEqual(incomingNames(incomingB), [nameA]);
  assert.ok(
    await b.waitFor("notice", (message) => String(message.text).includes("friend request"))
  );
  console.log("  [ok] friend request is pending, not immediate; the recipient is notified");

  a.drain("social_state");
  b.drain("social_state");
  b.send({ type: "friend_accept", playerId: idsA.characterId });
  const acceptedA = await a.waitFor(
    "social_state",
    (message) => (message.friends as Dict[]).length === 1
  );
  const acceptedB = await b.waitFor(
    "social_state",
    (message) => (message.friends as Dict[]).length === 1
  );
  assert.deepEqual(friendNames(acceptedA), [nameB]);
  assert.deepEqual(friendNames(acceptedB), [nameA]);
  assert.deepEqual(outgoingNames(acceptedA), []);
  assert.deepEqual(incomingNames(acceptedB), []);
  assert.equal((acceptedA.friends as Dict[])[0].online, true);
  assert.ok(acceptedA.friends[0].location, "online friends should expose a location");
  assert.ok(
    await a.waitFor("notice", (message) => String(message.text).includes("accepted"))
  );
  console.log("  [ok] accepting creates a mutual friendship and clears the request");

  a.send({ type: "direct_message", toId: idsB.characterId, text: "Want to trade later?" });
  const dmB = await b.waitFor("direct_message");
  assert.equal(dmB.fromId, idsA.characterId);
  assert.equal(dmB.fromName, nameA);
  assert.equal(dmB.text, "Want to trade later?");
  const dmA = await a.waitFor("direct_message");
  assert.equal(dmA.toId, idsB.characterId);
  assert.equal(dmA.outgoing, true);
  console.log("  [ok] friends can exchange direct messages");

  a.drain("social_state");
  b.drain("social_state");
  a.send({ type: "friend_remove", playerId: idsB.characterId });
  const removedA = await a.waitFor(
    "social_state",
    (message) => (message.friends as Dict[]).length === 0
  );
  const removedB = await b.waitFor(
    "social_state",
    (message) => (message.friends as Dict[]).length === 0
  );
  assert.deepEqual(friendNames(removedA), []);
  assert.deepEqual(friendNames(removedB), []);
  console.log("  [ok] removing a friend clears both sides");

  a.drain("social_state");
  b.drain("social_state");
  a.send({ type: "friend_request", playerId: idsB.characterId });
  await b.waitFor("social_state", (message) => (message.incomingRequests as Dict[]).length === 1);
  a.drain("social_state");
  b.drain("social_state");
  b.send({ type: "friend_decline", playerId: idsA.characterId });
  const declinedA = await a.waitFor(
    "social_state",
    (message) => (message.outgoingRequests as Dict[]).length === 0
  );
  assert.deepEqual(friendNames(declinedA), []);
  assert.ok(
    await a.waitFor("notice", (message) => String(message.text).includes("declined"))
  );
  console.log("  [ok] declining removes the request and tells the sender");

  a.drain("social_state");
  b.drain("social_state");
  a.send({ type: "friend_request", playerId: idsB.characterId });
  await b.waitFor("social_state", (message) => (message.incomingRequests as Dict[]).length === 1);
  a.drain("social_state");
  b.drain("social_state");
  a.send({ type: "friend_cancel", playerId: idsB.characterId });
  await a.waitFor(
    "social_state",
    (message) => (message.outgoingRequests as Dict[]).length === 0
  );
  assert.ok(
    await b.waitFor("notice", (message) => String(message.text).includes("canceled"))
  );
  console.log("  [ok] the sender can cancel a pending request");

  b.close();
  await sleep(500);
  const offlineA = await social(a);
  assert.deepEqual(friendNames(offlineA), []);
  a.drain("social_state");
  a.send({ type: "friend_request", playerId: idsB.characterId });
  const pendingOffline = await a.waitFor(
    "social_state",
    (message) => (message.outgoingRequests as Dict[]).length === 1
  );
  assert.deepEqual(outgoingNames(pendingOffline), [nameB]);
  console.log("  [ok] a request can be sent to an offline trainer");

  const b2 = new Client("B2");
  await b2.open();
  b2.send({ type: "resume", token: idsB.token });
  const authB2 = await b2.waitFor("auth_ok");
  assert.equal(authB2.character.name, nameB);
  await b2.waitFor("map_state");
  const pendingB2 = await social(b2);
  assert.deepEqual(incomingNames(pendingB2), [nameA]);
  a.drain("social_state");
  b2.drain("social_state");
  b2.send({ type: "friend_accept", playerId: idsA.characterId });
  const friendA2 = await a.waitFor(
    "social_state",
    (message) => (message.friends as Dict[]).length === 1
  );
  assert.equal((friendA2.friends as Dict[])[0].online, true);
  await b2.waitFor("social_state", (message) => (message.friends as Dict[]).length === 1);
  console.log("  [ok] pending requests survive a disconnect and re-accept online");

  b2.close();
  await sleep(500);
  const friendOffline = await social(a);
  assert.deepEqual(friendNames(friendOffline), [nameB]);
  assert.equal((friendOffline.friends as Dict[])[0].online, false);
  console.log("  [ok] friends stay listed while offline");

  const b3 = new Client("B3");
  await b3.open();
  b3.send({ type: "resume", token: idsB.token });
  await b3.waitFor("auth_ok");
  await b3.waitFor("map_state");
  await sleep(300);
  const friendOnline = await social(a);
  assert.equal((friendOnline.friends as Dict[])[0].online, true);
  console.log("  [ok] friend presence updates after reconnecting");

  a.send({ type: "friend_request", playerId: idsA.characterId });
  const selfError = await a.waitFor(
    "error",
    (message) => String(message.message).includes("cannot add yourself")
  );
  assert.ok(selfError);
  console.log("  [ok] self-add is rejected");

  a.drain("social_state");
  b3.drain("social_state");
  a.send({ type: "friend_remove", playerId: idsB.characterId });
  await a.waitFor("social_state", (message) => (message.friends as Dict[]).length === 0);
  await b3.waitFor("social_state", (message) => (message.friends as Dict[]).length === 0);
  console.log("  [ok] cleanup removal left both friend lists empty");

  a.close();
  b3.close();
  console.log("Social smoke test PASSED");
  process.exit(0);
}

main().catch((error) => {
  console.error("Social smoke test FAILED");
  console.error(error);
  process.exit(1);
});
