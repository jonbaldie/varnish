#!/usr/bin/env python3
"""Phase 3: Stateful Action-Sequence Testing with Replay & Minimization."""

import http.client
import json
import random
import time

class Action:
    def __init__(self, action_type, **kwargs):
        self.action_type = action_type
        self.params = kwargs

    def __repr__(self):
        return f"{self.action_type}({', '.join(f'{k}={v!r}' for k, v in self.params.items())})"

    def to_dict(self):
        return {"type": self.action_type, "params": self.params}


class StatefulHarness:
    def __init__(self, varnish_host, varnish_port, backend):
        self.varnish_host = varnish_host
        self.varnish_port = varnish_port
        self.backend = backend
        self.client_tokens = {} # client_id -> expected secret token

    def reset(self):
        """Reset system to known starting state: clear backend routes and purge cache."""
        self.backend.clear_routes()
        self.client_tokens.clear()
        # Verify reset probe: backend history must be 0
        assert len(self.backend.get_history()) == 0, "Reset failed: backend history not empty"

    def execute_action(self, action: Action):
        if action.action_type == "SET_ORIGIN":
            path = action.params["path"]
            status = action.params.get("status", 200)
            headers = action.params.get("headers", {})
            body = action.params.get("body", "default-body")
            self.backend.set_route(path, status=status, headers=headers, body=body)
            return None

        elif action.action_type == "CLIENT_REQUEST":
            client_id = action.params["client_id"]
            method = action.params.get("method", "GET")
            path = action.params["path"]
            headers = dict(action.params.get("headers", {}))
            
            # Send request
            conn = http.client.HTTPConnection(self.varnish_host, self.varnish_port, timeout=5)
            conn.request(method, path, headers=headers)
            resp = conn.getresponse()
            body = resp.read().decode("utf-8", errors="replace")
            resp_headers = {k.title(): v for k, v in resp.getheaders()}
            conn.close()

            return {
                "client_id": client_id,
                "status": resp.status,
                "headers": resp_headers,
                "body": body,
                "x_cache": resp_headers.get("X-Cache", ""),
                "set_cookie": resp_headers.get("Set-Cookie", None),
                "backend_id": resp_headers.get("X-Backend-Request-Id", None),
            }

        elif action.action_type == "PURGE":
            path = action.params["path"]
            conn = http.client.HTTPConnection(self.varnish_host, self.varnish_port, timeout=5)
            conn.request("PURGE", path)
            resp = conn.getresponse()
            resp.read()
            conn.close()
            return {"purge_status": resp.status}

        elif action.action_type == "TOGGLE_BACKEND":
            is_down = action.params["is_down"]
            self.backend.is_down = is_down
            return None

    def probe_invariants(self, action: Action, result):
        """Check invariants after an action. Return failure description or None."""
        if not result or "client_id" not in result:
            return None

        client_id = result["client_id"]
        headers = result["headers"]
        set_cookie = result.get("set_cookie")

        # Invariant 1: Set-Cookie must never be delivered from cache (X-Cache: HIT)
        if "HIT" in result.get("x_cache", "") and set_cookie:
            return (
                f"Set-Cookie served from cache! Client '{client_id}' received Set-Cookie '{set_cookie}' "
                f"with X-Cache: HIT"
            )

        # Invariant 2: Client isolation: a client must never receive a Set-Cookie intended for another client
        if set_cookie:
            for other_client, other_token in self.client_tokens.items():
                if other_client != client_id and other_token in set_cookie:
                    return (
                        f"Cross-client cookie leak! Client '{client_id}' received secret session "
                        f"'{other_token}' belonging to '{other_client}'"
                    )

        # Invariant 3: Private/no-store content must never be delivered from cache
        cache_control = headers.get("Cache-Control", "")
        if "HIT" in result.get("x_cache", ""):
            if "no-store" in cache_control:
                return f"Cache-Control: no-store response was delivered from cache (X-Cache: HIT)"
            if "private" in cache_control:
                return f"Cache-Control: private response was delivered from cache (X-Cache: HIT)"

        # Record tokens issued to clients
        if set_cookie and "session=" in set_cookie:
            token = set_cookie.split("session=")[1].split(";")[0]
            self.client_tokens[client_id] = token

        return None


def run_sequence(harness: StatefulHarness, sequence: list[Action]):
    """Run an entire sequence from clean reset. Returns (failed_step_index, error_message)."""
    harness.reset()
    for i, action in enumerate(sequence):
        res = harness.execute_action(action)
        err = harness.probe_invariants(action, res)
        if err:
            return i, err
    return None, None


def minimize_sequence(harness: StatefulHarness, sequence: list[Action]):
    """Delta-debug: reduce sequence to smallest sub-sequence reproducing 3 times."""
    current = list(sequence)
    
    # Verify initial sequence reproduces 3 times
    for _ in range(3):
        failed_idx, err = run_sequence(harness, current)
        if failed_idx is None:
            return None, "Initial failure was not stable across 3 runs"
    
    # Trim from the end (remove actions after failed step)
    failed_idx, err = run_sequence(harness, current)
    current = current[:failed_idx + 1]

    # Try removing actions one by one from the beginning or middle
    changed = True
    while changed:
        changed = False
        for i in range(len(current) - 1): # Keep the last action which triggers the failure
            candidate = current[:i] + current[i+1:]
            
            # Check if candidate reproduces 3 times
            reproduced = True
            for _ in range(3):
                idx, c_err = run_sequence(harness, candidate)
                if idx is None:
                    reproduced = False
                    break
            
            if reproduced:
                current = candidate
                changed = True
                break

    return current, err


def generate_random_sequences(num_sequences=50):
    sequences = []
    clients = ["alice", "bob", "carol"]
    routes = [
        "/auth/login",
        "/user/profile",
        "/assets/main.css",
        "/assets/main.css?v=1",
        "/data/report",
    ]

    for _ in range(num_sequences):
        seq = []
        path = random.choice(routes)
        
        # Action 1: Set origin route behavior
        has_set_cookie = random.choice([True, False])
        cc = random.choice(["public, max-age=60", "private, no-cache", "no-store", ""])
        headers = {}
        if has_set_cookie:
            headers["Set-Cookie"] = "session=token-{req_id}; Path=/;"
        if cc:
            headers["Cache-Control"] = cc

        seq.append(Action("SET_ORIGIN", path=path, headers=headers, body=f"content for {path}"))

        # Add 3-8 client requests
        for step in range(random.randint(3, 8)):
            c = random.choice(clients)
            action_choice = random.random()
            if action_choice < 0.15:
                # Purge
                seq.append(Action("PURGE", path=path))
            else:
                # Client request, maybe with cookie, maybe without
                req_headers = {}
                if random.choice([True, False]):
                    req_headers["Cookie"] = f"session={c}"
                seq.append(Action("CLIENT_REQUEST", client_id=c, path=path, headers=req_headers))

        sequences.append(seq)
    return sequences


def run_all(varnish_host="127.0.0.1", varnish_port=80, backend=None):
    print("==================================================================")
    print("PHASE 3: Stateful Action-Sequence Testing & Delta Minimization")
    print("==================================================================")
    
    harness = StatefulHarness(varnish_host, varnish_port, backend)
    sequences = generate_random_sequences(60)
    
    stateful_findings = []
    found_bugs = set()

    for seq_num, seq in enumerate(sequences):
        failed_idx, err = run_sequence(harness, seq)
        if failed_idx is not None:
            # Found a failure!
            prefix = seq[:failed_idx + 1]
            min_seq, stable_err = minimize_sequence(harness, prefix)
            if min_seq:
                signature = (stable_err.split(":")[0], len(min_seq))
                if signature not in found_bugs:
                    found_bugs.add(signature)
                    print(f"\n[STABLE BUG FOUND in sequence #{seq_num}]")
                    print(f"Error: {stable_err}")
                    print(f"Minimal sequence ({len(min_seq)} actions):")
                    for act in min_seq:
                        print(f"  -> {act}")

                    stateful_findings.append({
                        "category": "Stateful Sequence Failure",
                        "name": stable_err.split("!")[0],
                        "error": stable_err,
                        "minimal_sequence": [str(a) for a in min_seq],
                    })

    print(f"\nPhase 3 Complete. Unique stable minimal failure sequences found: {len(stateful_findings)}")
    return stateful_findings

if __name__ == "__main__":
    from backend import start_backend
    backend = start_backend(8080)
    res = run_all("127.0.0.1", 80, backend)
    print(json.dumps(res, indent=2))
