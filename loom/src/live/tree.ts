/**
 * Sending full HTML on every update would waste bandwidth —
 * most of a template is static markup that never changes. The
 * statics/dynamics tree format splits a template into fixed
 * strings (statics) and variable slots (dynamics), so the
 * server only sends diffs against the dynamic parts. This
 * module reconstructs full HTML from those trees and applies
 * incoming diffs in place.
 *
 * A "tree" is { s: string[], d: any[] } where statics and
 * dynamics interleave: s[0] + render(d[0]) + s[1] + ...
 * A dynamic value can be a leaf string, a nested subtree
 * { s, d } for conditionals/components, or an array of
 * subtrees for loop output.
 */

/**
 * After applying a diff to the dynamics array, morphdom needs a
 * full HTML string to diff against the current DOM. Interleaving
 * the unchanged statics with the updated dynamics produces that
 * string without the server ever re-sending the static parts.
 */
export function reconstruct(statics: string[], dynamics: any[]): string {
  let result = "";
  for (let i = 0; i < statics.length; i++) {
    result += statics[i];
    if (i < dynamics.length) {
      result += renderDynamic(dynamics[i]);
    }
  }
  return result;
}

/**
 * Dynamic slots can hold three kinds of values: plain strings
 * for simple interpolations, nested trees for conditionals and
 * components (which have their own statics/dynamics), and arrays
 * of trees for loop output. Dispatching on type here keeps the
 * reconstruct loop clean while handling the full tree grammar.
 */
export function renderDynamic(dyn: any): string {
  if (typeof dyn === "string") {
    return dyn;
  }
  if (Array.isArray(dyn)) {
    // List of trees
    return dyn.map((tree: any) => reconstruct(tree.s, tree.d)).join("");
  }
  if (dyn && typeof dyn === "object" && "s" in dyn && "d" in dyn) {
    // Nested tree
    return reconstruct(dyn.s, dyn.d);
  }
  return "";
}

/**
 * The server sends only the dynamic slots that changed, keyed by
 * their index in the dynamics array. Mutating the array in place
 * avoids allocating a new tree on every patch. The diff format
 * supports four cases: leaf replacement (string), full list swap
 * (array), full subtree swap like a branch flip ({ s, d }), and
 * nested diffs into an existing subtree or list ({ d }) for
 * changes deep in the tree without replacing the outer structure.
 */
export function applyDiff(dynamics: any[], diff: any): void {
  if (!diff || !dynamics) return;
  for (const key of Object.keys(diff)) {
    const idx = parseInt(key, 10);
    const value = diff[key];
    if (typeof value === "string") {
      dynamics[idx] = value;
    } else if (Array.isArray(value)) {
      dynamics[idx] = value;
    } else if (value && typeof value === "object") {
      if ("s" in value && "d" in value) {
        dynamics[idx] = value;
      } else if ("d" in value) {
        const existing = dynamics[idx];
        if (existing && typeof existing === "object") {
          if (Array.isArray(existing)) {
            applyListDiff(existing, value.d);
          } else if ("d" in existing) {
            applySubtreeDiff(existing, value.d);
          }
        }
      }
    }
  }
}

/**
 * Conditionals and components produce nested subtrees with their
 * own dynamics arrays. When only an inner value changes, the
 * server sends a nested diff ({ d }) rather than replacing the
 * entire subtree. Recursing into the subtree's dynamics applies
 * the same leaf/list/subtree/nested-diff logic at each level,
 * keeping the update granular regardless of nesting depth.
 */
export function applySubtreeDiff(tree: any, diff: any): void {
  if (!diff || !tree.d) return;
  for (const key of Object.keys(diff)) {
    const idx = parseInt(key, 10);
    const value = diff[key];
    if (typeof value === "string") {
      tree.d[idx] = value;
    } else if (Array.isArray(value)) {
      tree.d[idx] = value;
    } else if (value && typeof value === "object") {
      if ("s" in value && "d" in value) {
        tree.d[idx] = value;
      } else if ("d" in value) {
        const existing = tree.d[idx];
        if (existing && typeof existing === "object") {
          if (Array.isArray(existing)) {
            applyListDiff(existing, value.d);
          } else if ("d" in existing) {
            applySubtreeDiff(existing, value.d);
          }
        }
      }
    }
  }
}

/**
 * Loops produce arrays of subtrees — one per iteration. When
 * items change, the server sends a diff keyed by list index.
 * Each entry is either a full tree replacement (when an item's
 * statics change, e.g. a branch flip inside the loop body) or
 * a nested diff into the existing item's dynamics (when only
 * values changed). This avoids replacing the entire list when
 * a single item updates.
 */
export function applyListDiff(list: any[], diff: any): void {
  if (!diff) return;
  for (const key of Object.keys(diff)) {
    const idx = parseInt(key, 10);
    const value = diff[key];
    if (value && typeof value === "object") {
      if ("s" in value && "d" in value) {
        list[idx] = value;
      } else if ("d" in value) {
        if (list[idx] && typeof list[idx] === "object" && "d" in list[idx]) {
          applySubtreeDiff(list[idx], value.d);
        }
      }
    }
  }
}
