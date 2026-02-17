/**
 * Multiple live components share a single WebSocket, so each
 * server message needs a "type" discriminant for routing and an
 * optional "id" to target the correct multiplexed component.
 * The "s" and "d" fields carry the static/dynamic tree data for
 * the "trees" message type, while "html", "url", and "error"
 * serve their respective message types. Keeping all variants in
 * one flat interface avoids wrapper objects for what are simple
 * single-payload messages.
 */
export interface ServerMessage {
  type: "trees" | "patch" | "redirect" | "error";
  id?: string;
  s?: any[];
  d?: any;
  html?: string;
  url?: string;
  error?: string;
}

/**
 * The server-side actor for a component can't start until it
 * knows which template module to run and has a valid token.
 * Sending a join message over the shared socket registers this
 * component's ID with the server, which validates the token
 * before spawning an actor. The ID ties all subsequent events
 * and patches to this specific component instance.
 */
export interface JoinPayload {
  type: "join";
  id: string;
  module: string;
  token: string;
}

/**
 * Mirrors the server-side ClientEvent structure so the JSON
 * serialized here deserializes directly into the Gleam type
 * without transformation. The "id" field routes the event to
 * the correct actor on the shared socket, and special_vars
 * carries browser-only state the server needs to update props.
 */
export interface EventPayload {
  type: "event";
  id: string;
  handler: string;
  event: string;
  special_vars: SpecialVars;
}

/**
 * Server-side actors hold state and consume resources, so they
 * must be explicitly stopped when a component is removed — for
 * example, during SPA navigation or when a container is removed
 * from the DOM. Sending a leave message lets the server clean
 * up the actor immediately rather than waiting for a WebSocket
 * timeout.
 */
export interface LeavePayload {
  type: "leave";
  id: string;
}

/**
 * A discriminated union of all client-to-server messages so the
 * send path can accept any valid outbound message and
 * TypeScript enforces that each variant has the required fields.
 * This keeps the socket's send method type-safe without per-
 * message-type overloads.
 */
export type ClientMessage = JoinPayload | EventPayload | LeavePayload;

/**
 * Server-side handlers need browser-only state — input values,
 * checkbox state, pressed keys — to update props without a
 * round-trip. All fields are optional because each event type
 * only provides the variables relevant to it: clicks have none,
 * inputs have value, checkboxes have checked, and keyboard
 * events have key.
 */
export interface SpecialVars {
  value?: string;
  checked?: boolean;
  key?: string;
}

/**
 * Event modifiers are parsed once from data attributes when
 * listeners attach, then reused on every event fire. Typing
 * them as a struct avoids re-reading the DOM on each event and
 * makes the modifier logic in handleEvent a simple property
 * check rather than attribute parsing.
 */
export interface Modifiers {
  prevent: boolean;
  stop: boolean;
  shouldDebounce: boolean;
  debounce: number;
}

/**
 * Client-side navigation fetches pages as HTML but only needs
 * to swap the body and update the head. Caching the parsed
 * parts — body HTML, title, and categorized head elements —
 * avoids re-fetching and re-parsing on back/forward navigation.
 * The resolvedUrl tracks redirects so the address bar shows the
 * final URL, and the timestamp enables cache expiration.
 */
export interface NavCacheEntry {
  html: string;
  title: string;
  headMeta: string[];
  headLinks: string[];
  headStyles: string[];
  resolvedUrl?: string;
  timestamp: number;
}

/**
 * The popstate event fires for all history entries, not just
 * Loom-managed ones. Storing a loomNavId marker in
 * history.state lets the nav handler distinguish its own
 * entries from external ones and decide whether to intercept
 * the navigation or let the browser handle it natively.
 */
export interface NavHistoryState {
  loomNavId: string;
  url: string;
}

/**
 * morphdom replaces DOM nodes during patching, destroying the
 * browser's focus and cursor position. Capturing this state
 * before a patch and restoring it after lets the user keep
 * typing uninterrupted. The handlerId provides a stable lookup
 * key to re-find the "same" input in the post-patch DOM since
 * the element reference itself may no longer exist.
 */
export interface FocusState {
  element: Element | null;
  isInput: boolean;
  selectionStart: number | null;
  selectionEnd: number | null;
  handlerId: string | undefined;
}
