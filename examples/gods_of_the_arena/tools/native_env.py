"""ctypes binding for libgota_env (native_env.h), used by the GotA neural tools."""
import ctypes, json, os
import numpy as np

SEATS, HEADS, STATS, ORDERS = 10, 5, 24, 16
HEAD_SIZES = [8, 25, 49, 4, 6]
STAT_NAMES = ["score", "outcome", "xp", "gold", "hero_kills", "assists", "deaths", "last_hits",
              "neutral_kills", "tower_damage", "structure_kills", "hero_damage", "damage_taken",
              "push_depth", "god_damage", "level", "gold_now", "team", "class", "alive",
              "decisions", "invalid_actions", "basic_max_instructions", "reserved"]


class Lib:
    def __init__(self, path=None):
        path = path or os.environ.get("GOTA_ENV_LIB", "libgota_env.so")
        L = self.L = ctypes.CDLL(path)
        vp, f32p, i32p, i64p = ctypes.c_void_p, ctypes.POINTER(ctypes.c_float), ctypes.POINTER(ctypes.c_int32), ctypes.POINTER(ctypes.c_int64)
        L.gota_create.restype = vp
        L.gota_create.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int32]
        L.gota_destroy.argtypes = [vp]
        L.gota_reset.argtypes = [vp, ctypes.c_int64]
        L.gota_observe_seats.argtypes = [vp, ctypes.c_uint32, f32p, f32p, f32p]
        L.gota_step.argtypes = [vp, i32p, f32p, f32p]
        L.gota_results.argtypes = [vp, f32p]
        L.gota_state_hash.restype = ctypes.c_uint64
        L.gota_state_hash.argtypes = [vp]
        L.gota_seat_stats.argtypes = [vp, ctypes.c_int, i64p]
        L.gota_set_seat_goal.argtypes = [vp, ctypes.c_int, f32p]
        L.gota_set_seat_script.argtypes = [vp, ctypes.c_int, ctypes.c_char_p, ctypes.c_int32]
        L.gota_seat_orders.argtypes = [vp, ctypes.c_int, i32p]
        L.gota_set_seat_override.argtypes = [vp, ctypes.c_int, ctypes.c_int32]
        L.gota_set_seat_package.argtypes = [vp, ctypes.c_int, ctypes.c_char_p, ctypes.c_int64]
        L.gota_seat_script_status.argtypes = [vp, ctypes.c_int, ctypes.c_char_p, ctypes.c_int32]
        L.gota_set_learner_seats.argtypes = [vp, ctypes.c_uint32]
        L.gota_battle_tick.argtypes = [vp]
        L.gota_save_replay.argtypes = [vp, ctypes.c_char_p]
        L.gota_last_error.argtypes = [ctypes.c_char_p, ctypes.c_int32]
        L.gota_net_load.restype = vp
        L.gota_net_load.argtypes = [ctypes.c_char_p, ctypes.c_int64, ctypes.c_char_p, ctypes.c_int32]
        L.gota_net_infer.argtypes = [vp, f32p, f32p, f32p]
        L.gota_net_info.argtypes = [vp, i64p]
        L.gota_observation_contract_hash.argtypes = [ctypes.c_char_p, ctypes.c_int32]
        L.gota_action_contract_hash.argtypes = [ctypes.c_char_p, ctypes.c_int32]
        self.obs_size = L.gota_observation_size()

    def hashes(self):
        a, b = ctypes.create_string_buffer(65), ctypes.create_string_buffer(65)
        self.L.gota_observation_contract_hash(a, 65)
        self.L.gota_action_contract_hash(b, 65)
        return a.value.decode(), b.value.decode()

    def last_error(self):
        b = ctypes.create_string_buffer(1024)
        self.L.gota_last_error(b, 1024)
        return b.value.decode()


def ptr(a, t):
    return a.ctypes.data_as(ctypes.POINTER(t))


class Env:
    def __init__(self, lib, **config):
        self.lib, self.L = lib, lib.L
        err = ctypes.create_string_buffer(1024)
        self.h = self.L.gota_create(json.dumps(config).encode(), err, 1024)
        if not self.h:
            raise RuntimeError(err.value.decode())
        self.obs = np.zeros((SEATS, lib.obs_size), np.float32)
        self.resets = np.zeros(SEATS, np.float32)
        self.acting = np.zeros(SEATS, np.float32)
        self.rewards = np.zeros(SEATS, np.float32)
        self.terms = np.zeros(SEATS, np.float32)

    def reset(self, seed):
        r = self.L.gota_reset(self.h, seed)
        if r == -3:
            raise RuntimeError(self.lib.last_error())
        return r

    def observe(self, mask=0x3FF):
        assert self.L.gota_observe_seats(self.h, mask, ptr(self.obs, ctypes.c_float), ptr(self.resets, ctypes.c_float), ptr(self.acting, ctypes.c_float)) == 0
        return self.obs, self.resets, self.acting

    def step(self, actions):
        a = np.ascontiguousarray(actions, np.int32)
        r = self.L.gota_step(self.h, ptr(a, ctypes.c_int32), ptr(self.rewards, ctypes.c_float), ptr(self.terms, ctypes.c_float))
        if r < 0:
            raise RuntimeError("gota_step %d %s" % (r, self.lib.last_error()))
        return r

    def results(self):
        out = np.zeros(8, np.float32)
        self.L.gota_results(self.h, ptr(out, ctypes.c_float))
        return out

    def stats(self, seat):
        out = np.zeros(STATS, np.int64)
        self.L.gota_seat_stats(self.h, seat, ptr(out, ctypes.c_int64))
        return out

    def orders(self, seat):
        out = np.zeros(ORDERS, np.int32)
        self.L.gota_seat_orders(self.h, seat, ptr(out, ctypes.c_int32))
        return out

    def state_hash(self):
        return self.L.gota_state_hash(self.h)

    def set_script(self, seat, source):
        b = source.encode()
        return self.L.gota_set_seat_script(self.h, seat, b, len(b))

    def set_override(self, seat, on):
        return self.L.gota_set_seat_override(self.h, seat, int(on))

    def set_package(self, seat, data):
        return self.L.gota_set_seat_package(self.h, seat, data, len(data))

    def set_goal(self, seat, w):
        w = np.ascontiguousarray(w, np.float32)
        return self.L.gota_set_seat_goal(self.h, seat, ptr(w, ctypes.c_float))

    def status(self, seat):
        b = ctypes.create_string_buffer(2048)
        code = self.L.gota_seat_script_status(self.h, seat, b, 2048)
        return code, b.value.decode()

    def save_replay(self, path):
        return self.L.gota_save_replay(self.h, path.encode())

    def close(self):
        if self.h:
            self.L.gota_destroy(self.h)
            self.h = None


def random_actions(rng, n=SEATS):
    return np.stack([rng.integers(0, s, n) for s in HEAD_SIZES], 1).astype(np.int32)
