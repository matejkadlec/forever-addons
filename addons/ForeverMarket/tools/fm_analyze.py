#!/usr/bin/env python3
"""ForeverMarket analyzer: market questions answered from the saved data, outside the game.

Reads the ForeverMarket saved variables (and optionally Auctionator / ForeverArtisan ones) and
prints tables; it writes nothing. Standard library only, Python 3.8+.

Usage (from anywhere):
  python3 fm_analyze.py summary
  python3 fm_analyze.py item "Camp Tent"
  python3 fm_analyze.py price "Camp Tent" --hours 8 --conf 0.9 --qty 20 --cost 240
  python3 fm_analyze.py movers
  python3 fm_analyze.py sales
  python3 fm_analyze.py craft --prof Leatherworking
  python3 fm_analyze.py flips --budget 5g
  python3 fm_analyze.py room [item ...] [--days 7] [--share 25]
  python3 fm_analyze.py listings [--rows 40] [--resamples 1000] [--plans 5] [--older <ForeverMarket.lua copy> ...]

Paths are found automatically (the game's WTF folder next to the AddOns folder, or one mounted at
~/mnt/WTF); override with --sv <ForeverMarket.lua> and --addon <AddOns/ForeverMarket folder>.
"""

import argparse
import bisect
import glob
import math
import os
import random
import re
import statistics
import sys
import time

EPOCH = 1767225600  # minutes since this moment (2026-01-01 UTC) in all ForeverMarket stamps
AUCTIONATOR_DAY0 = None  # computed from local time like Auctionator (2020-01-01 00:00 local)
AH_CUT = 0.05
CLEAN_GAP_MIN = 8 * 60  # longer deep scan gaps cannot tell sales from expiries (Forever lists for 2/8/24h)
MIN_COVER_H = 2.0  # hours of usable scan intervals before a sales rate is shown
POST_HOURS = {'1': 2, '2': 8, '3': 24}  # Forever post durations by the PostItem duration index

# --------------------------------------------------------------------------- Lua saved variables

_TOKEN = re.compile(r'''
    (?P<ws>\s+)
  | (?P<comment>--[^\n]*)
  | (?P<str>"(?:[^"\\]|\\.)*")
  | (?P<num>-?(?:\d+\.?\d*(?:[eE][-+]?\d+)?|\.\d+)|-?inf(?![A-Za-z0-9_])|-?nan(?![A-Za-z0-9_]))
  | (?P<name>[A-Za-z_][A-Za-z0-9_]*)
  | (?P<sym>[\[\]{}=,;])
''', re.S | re.X)

_ESCAPES = {'n': '\n', 't': '\t', 'r': '\r', '\\': '\\', '"': '"', "'": "'", 'a': '\a', 'b': '\b',
            'f': '\f', 'v': '\v', '\n': '\n'}


def _unescape(body):
    if '\\' not in body:
        return body
    out = []
    i, n = 0, len(body)
    while i < n:
        ch = body[i]
        if ch != '\\':
            out.append(ch)
            i += 1
            continue
        nxt = body[i + 1]
        if nxt.isdigit():
            j = i + 1
            while j < n and j < i + 4 and body[j].isdigit():
                j += 1
            out.append(chr(int(body[i + 1:j])))
            i = j
        else:
            out.append(_ESCAPES.get(nxt, nxt))
            i += 2
    return ''.join(out)


def _tokens(text):
    for m in _TOKEN.finditer(text):
        kind = m.lastgroup
        if kind in ('ws', 'comment'):
            continue
        yield kind, m.group(kind)


class _Parser:
    def __init__(self, text):
        self.it = _tokens(text)
        self.tok = next(self.it, (None, None))

    def advance(self):
        tok = self.tok
        self.tok = next(self.it, (None, None))
        return tok

    def expect(self, value):
        kind, val = self.advance()
        if val != value:
            raise ValueError('expected %r, got %r' % (value, val))

    def value(self):
        kind, val = self.advance()
        if kind == 'str':
            return _unescape(val[1:-1])
        if kind == 'num':
            if val in ('inf', '-inf', 'nan', '-nan'):
                return float(val)
            f = float(val)
            return int(f) if f.is_integer() and 'e' not in val.lower() and '.' not in val else f
        if kind == 'name':
            return {'true': True, 'false': False, 'nil': None}.get(val, val)
        if val == '{':
            return self.table()
        raise ValueError('unexpected token %r' % (val,))

    def table(self):
        result = {}
        index = 1
        while True:
            kind, val = self.tok
            if val == '}':
                self.advance()
                return result
            if val == '[':
                self.advance()
                key = self.value()
                self.expect(']')
                self.expect('=')
                result[key] = self.value()
            else:
                result[index] = self.value()
                index += 1
            kind, val = self.tok
            if val in (',', ';'):
                self.advance()


def load_saved_variables(path):
    """{global name: value} of a WoW SavedVariables file (latin-1 text keeps raw bytes)."""
    with open(path, 'rb') as fh:
        text = fh.read().decode('latin-1')
    parser = _Parser(text)
    out = {}
    while parser.tok[0] is not None:
        kind, name = parser.advance()
        if kind != 'name':
            continue
        parser.expect('=')
        out[name] = parser.value()
    return out


def as_list(table):
    if isinstance(table, list):
        return table
    if not isinstance(table, dict):
        return []
    return [table[i] for i in range(1, len(table) + 1) if i in table]


def fix_text(s):
    """latin-1 decoded UTF-8 -> proper text."""
    if not isinstance(s, str):
        return s
    try:
        return s.encode('latin-1').decode('utf-8')
    except (UnicodeDecodeError, UnicodeEncodeError):
        return s

# --------------------------------------------------------------------------- CBOR (Auctionator)


def cbor_loads(data):
    pos = 0

    def read(n):
        nonlocal pos
        chunk = data[pos:pos + n]
        pos += n
        return chunk

    def length(info):
        if info < 24:
            return info
        size = {24: 1, 25: 2, 26: 4, 27: 8}.get(info)
        if size is None:
            return None  # indefinite
        return int.from_bytes(read(size), 'big')

    def item():
        nonlocal pos
        initial = data[pos]
        pos += 1
        major, info = initial >> 5, initial & 31
        if major == 0:
            return length(info)
        if major == 1:
            return -1 - length(info)
        if major in (2, 3):
            n = length(info)
            if n is None:
                parts = []
                while data[pos] != 0xff:
                    parts.append(item())
                pos += 1
                raw = b''.join(p if isinstance(p, bytes) else p.encode('latin-1') for p in parts)
            else:
                raw = read(n)
            return raw if major == 2 else raw.decode('utf-8', 'replace')
        if major == 4:
            n = length(info)
            if n is None:
                out = []
                while data[pos] != 0xff:
                    out.append(item())
                pos += 1
                return out
            return [item() for _ in range(n)]
        if major == 5:
            n = length(info)
            out = {}
            if n is None:
                while data[pos] != 0xff:
                    k = item()
                    out[k] = item()
                pos += 1
                return out
            for _ in range(n):
                k = item()
                out[k] = item()
            return out
        if major == 6:
            length(info)
            return item()
        # major 7
        if info == 20:
            return False
        if info == 21:
            return True
        if info in (22, 23):
            return None
        import struct
        if info == 25:
            h = int.from_bytes(read(2), 'big')
            sign = -1 if h & 0x8000 else 1
            exp, frac = (h >> 10) & 0x1f, h & 0x3ff
            if exp == 0:
                return sign * frac * 2 ** -24
            if exp == 31:
                return sign * float('inf') if frac == 0 else float('nan')
            return sign * (1 + frac / 1024) * 2 ** (exp - 15)
        if info == 26:
            return struct.unpack('>f', read(4))[0]
        if info == 27:
            return struct.unpack('>d', read(8))[0]
        return None

    return item()

# --------------------------------------------------------------------------- formatting


def b36(s):
    if s is None or s == '':
        return None
    try:
        return int(s, 36)
    except ValueError:
        return None


def money(c):
    if c is None:
        return '-'
    c = int(round(c))
    sign = '-' if c < 0 else ''
    c = abs(c)
    g, s, cc = c // 10000, (c // 100) % 100, c % 100
    if g:
        return '%s%dg %02ds %02dc' % (sign, g, s, cc)
    if s:
        return '%s%ds %02dc' % (sign, s, cc)
    return '%s%dc' % (sign, cc)


def parse_money(text):
    """'3s50c', '1g2s', '350' (copper) -> copper"""
    if text is None:
        return None
    t = str(text).replace(' ', '').lower()
    if re.fullmatch(r'\d+', t):
        return int(t)
    total = 0
    for amount, unit in re.findall(r'(\d+)([gsc])', t):
        total += int(amount) * {'g': 10000, 's': 100, 'c': 1}[unit]
    return total


def stamp_to_epoch(s):
    m = b36(s)
    return None if m is None else EPOCH + m * 60


def ago(epoch, now=None):
    if epoch is None:
        return '?'
    d = (now or time.time()) - epoch
    if d < 3600:
        return '%dm' % (d // 60)
    if d < 172800:
        return '%.1fh' % (d / 3600)
    return '%.1fd' % (d / 86400)


def when(epoch):
    return time.strftime('%d.%m. %H:%M', time.localtime(epoch)) if epoch else '?'


def table(rows, headers):
    rows = [[str(c) for c in r] for r in rows]
    widths = [len(h) for h in headers]
    for r in rows:
        for i, c in enumerate(r):
            widths[i] = max(widths[i], len(c))
    line = '  '.join(h.ljust(widths[i]) for i, h in enumerate(headers))
    print(line)
    print('  '.join('-' * w for w in widths))
    for r in rows:
        print('  '.join(c.rjust(widths[i]) if i else c.ljust(widths[i]) for i, c in enumerate(r)))

# --------------------------------------------------------------------------- paths


def find_paths(args):
    here = os.path.dirname(os.path.abspath(__file__))
    addon = args.addon or os.path.dirname(here)
    if args.sv:
        sv = args.sv
    else:
        candidates = []
        roots = [os.path.join(addon, '..', '..', '..', 'WTF'), os.path.expanduser('~/mnt/WTF')]
        for root in roots:
            candidates += glob.glob(os.path.join(root, 'Account', '*', 'SavedVariables', 'ForeverMarket.lua'))
        if not candidates:
            sys.exit('ForeverMarket.lua saved variables not found (play once, /reload, or pass --sv)')
        sv = max(candidates, key=os.path.getmtime)
    return os.path.abspath(addon), os.path.abspath(sv)

# --------------------------------------------------------------------------- market data

DEEP_FIELDS = ['t', 'min', 'qty', 'n', 'q5', 'q20', 'median', 'own', 'gap', 'sold', 'soldN', 'soldVal',
               'amb', 'rep', 'new', 'newMin', 'ladder', 'sales', 'newLadder', 'ownMin', 'minOther', 'soldLow']
CARRIED = ['min', 'qty', 'n', 'q5', 'q20', 'median', 'own', 'ladder', 'ownMin', 'minOther']


def parse_ladder(s):
    out = []
    for part in (s or '').split('/'):
        bits = part.split(':')
        if len(bits) >= 2 and bits[0]:
            out.append(tuple(b36(b) or 0 for b in bits))
    return out


def character_settings(account, realm, char=None):
    """The settings the AddOn's plan reads for one character (1.68, FRV-228): the account-wide ones
    (ForeverMarketDB.settings, kept as they were before 1.68) with that character's own on top
    (realms[...].settings[char]: filters, the Picks row, the shares of C/24h, the Profit rule). char = its key or
    full name, any case; without one the character with settings that was seen last. Returns (settings, key or None)"""
    settings = dict(account or {})
    own = realm.get('settings') if isinstance(realm, dict) else None
    if not isinstance(own, dict) or not own:
        return settings, None
    info = realm.get('charInfo') if isinstance(realm.get('charInfo'), dict) else {}
    key = None
    if char:
        want = char.lower()
        for k in own:
            full = (info.get(k) or {}).get('full') if isinstance(info.get(k), dict) else None
            if k.lower() == want or (isinstance(full, str) and full.lower() == want):
                key = k
        if key is None:
            sys.exit('No settings of the character %s, known: %s' % (char, ', '.join(sorted(own))))
    else:
        def seen(k):
            e = info.get(k)
            return (e.get('seen') or 0) if isinstance(e, dict) else 0
        key = max(sorted(own), key=seen)
    if isinstance(own.get(key), dict):
        settings.update(own[key])
    return settings, key


class Market:
    def __init__(self, sv_path, realm=None, char=None):
        self.sv_path = sv_path
        self.sv_dir = os.path.dirname(sv_path)
        self.saved_at = os.path.getmtime(sv_path)
        data = load_saved_variables(sv_path).get('ForeverMarketDB') or {}
        realms = data.get('realms') or {}
        if not realms:
            sys.exit('No market data yet.')
        if realm:
            matches = [k for k in realms if realm.lower() in k.lower()]
            if not matches:
                sys.exit('Realm not found, known: ' + ', '.join(realms))
            self.realm_key = matches[0]
        else:
            def last_scan(k):
                scans = as_list(realms[k].get('scans'))
                return stamp_to_epoch(scans[-1].split(',')[0][1:]) if scans else 0
            self.realm_key = max(realms, key=last_scan)
        self.r = realms[self.realm_key]
        self.settings, self.char = character_settings(data.get('settings'), self.r, char)
        self.items = self.r.get('items') or {}
        self.names = {k: fix_text(v) for k, v in (self.r.get('names') or {}).items()}
        self.watch = self.r.get('watch') or {}
        self.scans = [s.split(',') for s in as_list(self.r.get('scans'))]
        self._auctionator = None
        self.now = time.time()

    # ---- names
    def name(self, key):
        return self.names.get(str(key)) or self.extra_names().get(str(key)) or 'item:%s' % key

    def extra_names(self):
        if not hasattr(self, '_extra_names'):
            self._extra_names = {}
        return self._extra_names

    def find(self, query):
        q = str(query).strip()
        if q in self.items or q in self.names:
            return [q]
        m = re.search(r'item:(\d+)', q)
        if m:
            return [m.group(1)]
        if q.isdigit():
            return [q]
        low = q.lower()
        exact = [k for k, n in self.names.items() if n.lower() == low]
        if exact:
            return exact
        return sorted([k for k, n in self.names.items() if low in n.lower()], key=lambda k: len(self.names[k]))

    # ---- records
    def records(self, key):
        item = self.items.get(str(key)) or {}
        out = []
        last_full = None
        for raw in (item.get('d') or '').split(';'):
            if not raw:
                continue
            f = raw.split(',')
            kind, t = f[0][0], stamp_to_epoch(f[0][1:])
            if kind == 'b':
                out.append({'kind': 'b', 't': t, 'min': b36(f[1]) if len(f) > 1 else None,
                            'qty': b36(f[2]) if len(f) > 2 else 0, 'own': len(f) > 3 and f[3] == '1'})
                continue
            if len(f) > 1 and f[1] == '=':
                rec = {k: (last_full or {}).get(k) for k in CARRIED}
                rec.update({'kind': 'r', 't': t, 'gap': b36(f[2]) if len(f) > 2 else None, 'unchanged': True})
                for k in ('sold', 'soldN', 'soldVal', 'amb', 'rep', 'new', 'soldLow'):
                    rec[k] = 0
                out.append(rec)
                continue
            rec = {'kind': 'r', 't': t}
            for i, name in enumerate(DEEP_FIELDS[1:], start=1):
                v = f[i] if i < len(f) else ''
                if name in ('ladder', 'sales', 'newLadder'):
                    rec[name] = parse_ladder(v)
                else:
                    rec[name] = b36(v)
            for k in ('sold', 'soldN', 'soldVal', 'amb', 'rep', 'new', 'own', 'qty', 'n'):
                rec[k] = rec[k] or 0
            last_full = rec
            out.append(rec)
        return out

    def rollups(self, key):
        item = self.items.get(str(key)) or {}
        out = []
        for raw in (item.get('r') or '').split(';'):
            f = raw.split(',')
            if len(f) < 10:
                continue
            day = b36(f[0][1:])
            n, n_min, min_min, sum_min, sum_qty, sold, sold_val, amb, gap = (b36(x) or 0 for x in f[1:10])
            out.append({'day': day, 'date': EPOCH + day * 86400, 'n': n, 'minMin': min_min or None,
                        'avgMin': sum_min / n_min if n_min else None, 'avgQty': sum_qty / n if n else 0,
                        'sold': sold, 'soldVal': sold_val, 'amb': amb, 'gap': gap})
        return out

    def searches(self, key):
        item = self.items.get(str(key)) or {}
        out = []
        for raw in (item.get('s') or '').split(';'):
            f = raw.split(',')
            if len(f) < 5:
                continue
            rec = {'t': stamp_to_epoch(f[0][1:]), 'kind': f[1], 'full': f[2] == '1', 'n': b36(f[3]) or 0,
                   'ladder': parse_ladder(f[4])}
            if len(f) >= 10 and f[5]:
                rec.update({'gap': b36(f[5]), 'sold': b36(f[6]) or 0, 'soldVal': b36(f[7]) or 0,
                            'rep': b36(f[8]) or 0, 'new': b36(f[9]) or 0})
            out.append(rec)
        return out

    # ---- derived
    def demand(self, key, hours=72):
        """Units bought per hour: deep scan diffs + exact search diffs within the window.

        Only deep scan intervals up to CLEAN_GAP_MIN count: over longer gaps every vanished auction could
        have expired, so they cannot tell sales apart. Rates stay None below MIN_COVER_H hours of usable
        intervals, because a 20 minute window extrapolated to a day is noise."""
        since = self.now - hours * 3600
        sold = amb = new = 0.0
        cover = 0.0
        intervals = long_skipped = 0
        new_ratios = []
        prev_min = None
        for rec in self.records(key):
            if rec['kind'] != 'r':
                continue
            if rec['t'] and rec['t'] >= since and rec.get('gap'):
                if rec['gap'] > CLEAN_GAP_MIN:
                    long_skipped += 1
                    prev_min = rec.get('min') or prev_min
                    continue
                cover += rec['gap'] / 60
                sold += rec['sold']
                amb += rec['amb']
                new += rec['new']
                intervals += 1
                if prev_min and rec.get('newLadder'):
                    for level in rec['newLadder']:
                        new_ratios.append((level[0] / prev_min, level[1]))
            prev_min = rec.get('min') or prev_min
        s_sold = s_cover = 0.0
        for rec in self.searches(key):
            # exact by auction ID, but over long gaps cancelled auctions pile up among the "sold" ones
            if rec['t'] and rec['t'] >= since and rec.get('gap') and rec['gap'] <= CLEAN_GAP_MIN:
                s_sold += rec['sold']
                s_cover += rec['gap'] / 60
        if cover < MIN_COVER_H:  # fall back to the daily rollups (older than 72h, provable sales only)
            for roll in self.rollups(key)[-7:]:
                cover += roll['gap'] / 60
                sold += roll['sold']
        rate_low = sold / cover if cover else None
        rate_mid = (sold + 0.5 * amb) / cover if cover else None
        rate_high = (sold + amb) / cover if cover else None
        new_rate = new / cover if cover else None
        if s_cover >= 1 and rate_mid is not None and cover >= MIN_COVER_H:
            # exact search diffs are short but precise: pool them
            rate_mid = (rate_mid * cover + (s_sold / s_cover) * s_cover * 0.5) / (cover + s_cover * 0.5)
        elif s_cover >= MIN_COVER_H and s_cover > cover:
            rate_low = rate_mid = rate_high = s_sold / s_cover
            cover = s_cover
        if cover < MIN_COVER_H:
            rate_low = rate_mid = rate_high = None
        return {'low': rate_low, 'mid': rate_mid, 'high': rate_high, 'cover': cover, 'intervals': intervals,
                'longSkipped': long_skipped, 'newRate': new_rate, 'newRatios': new_ratios}

    def current(self, key):
        """Freshest view of the market: ladder, min, qty, age."""
        recs = self.records(key)
        deep = next((r for r in reversed(recs) if r['kind'] == 'r'), None)
        browse = next((r for r in reversed(recs) if r['kind'] == 'b'), None)
        search = next(iter(reversed(self.searches(key))), None)
        view = {'source': None, 't': None, 'min': None, 'qty': 0, 'ladder': None, 'approx': False}
        candidates = []
        if deep:
            candidates.append(('deep', deep['t'], deep))
        if browse:
            candidates.append(('browse', browse['t'], browse))
        if search:
            candidates.append(('search', search['t'], search))
        if not candidates:
            return view
        source, t, rec = max(candidates, key=lambda c: c[1] or 0)
        view.update({'source': source, 't': t})
        if source == 'search':
            view['ladder'] = [(u, q) for u, q in rec['ladder']]
            view['min'] = rec['ladder'][0][0] if rec['ladder'] else None
            view['qty'] = sum(q for _, q in rec['ladder'])
            view['partial'] = not rec['full'] or rec['n'] > len(rec['ladder'])
        else:
            view['min'] = rec.get('min')
            view['qty'] = rec.get('qty') or 0
            ladder = deep.get('ladder') if deep and source == 'deep' else None
            if not ladder and source == 'deep':
                ladder = self.last_scan_ladder(key, deep['t'])
            if ladder:
                view['ladder'] = [(u, q) for u, q in ladder]
            elif deep and deep.get('min'):
                view['ladder'] = approx_ladder(deep)
                view['approx'] = True
            elif rec.get('min'):
                view['ladder'] = [(rec['min'], rec.get('qty') or 0)]
                view['approx'] = True
        return view

    def has_variants(self, key):
        """random suffix item (the AddOn saw different names under this item ID)"""
        return (self.items.get(str(key)) or {}).get('v') == 1

    def last_scan_ladder(self, key, t, skip_own=False):
        """Exact price ladder of the newest deep scan, from its auction fingerprints (kept for every item)."""
        last = self.r.get('last') or {}
        if not last.get('t') or abs(last['t'] - t) > 120:
            return None
        fps = (last.get('fp') or {}).get(str(key))
        if not fps:
            return None
        levels = {}
        for fp in fps.split(','):
            bits = fp.split(':')
            if len(bits) < 3 or (skip_own and bits[0] == '@'):
                continue
            count, buyout = b36(bits[1]) or 1, b36(bits[2]) or 0
            unit = int(buyout / count + 0.5)
            levels[unit] = levels.get(unit, 0) + count
        return sorted(levels.items()) or None

    # ---- Auctionator history
    def auctionator(self):
        if self._auctionator is not None:
            return self._auctionator
        self._auctionator = {}
        path = os.path.join(self.sv_dir, 'Auctionator.lua')
        if not os.path.exists(path):
            return self._auctionator
        try:
            sv = load_saved_variables(path)
            db = sv.get('AUCTIONATOR_PRICE_DATABASE') or {}
            blobs = [(k, v) for k, v in db.items() if k != '__dbversion' and isinstance(v, str)]
            if blobs:
                _, blob = max(blobs, key=lambda kv: len(kv[1]))
                raw = cbor_loads(blob.encode('latin-1'))
                for key, value in raw.items():
                    if isinstance(value, (bytes, bytearray)):
                        value = cbor_loads(bytes(value))  # older per item CBOR format
                    value = _str_keys(value)
                    if isinstance(value, dict):
                        self._auctionator[_text(key)] = value
            self.vendor = {str(k): v for k, v in (sv.get('AUCTIONATOR_VENDOR_PRICE_CACHE') or {}).items()}
        except Exception as exc:  # history is optional
            print('(Auctionator history not readable: %s)' % exc)
        return self._auctionator

    def vendor_price(self, key):
        self.auctionator()
        return getattr(self, 'vendor', {}).get(str(key))


def _text(value):
    return value.decode('latin-1') if isinstance(value, (bytes, bytearray)) else str(value)


def _str_keys(value):
    """WoW's CBOR writes strings as byte strings: make dict keys plain text, recursively."""
    if isinstance(value, dict):
        return {_text(k): _str_keys(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_str_keys(v) for v in value]
    return value


def approx_ladder(rec):
    """Piecewise ladder from deep record stats when no full ladder is stored."""
    m, qty = rec['min'], rec.get('qty') or 0
    q5, q20, med = rec.get('q5') or 0, rec.get('q20') or 0, rec.get('median') or m
    pts = [(m, max(1, q5 // 2)), (int(m * 1.05), max(0, q5 - q5 // 2)), (int(m * 1.2), max(0, q20 - q5))]
    rest = max(0, qty - q20)
    if rest:
        pts.append((max(int(m * 1.2) + 1, med), rest // 2))
        pts.append((max(int(m * 1.2) + 2, int(med * 1.3)), rest - rest // 2))
    return [p for p in pts if p[1] > 0]

# --------------------------------------------------------------------------- price model


def _poisson(lam, rng):
    if lam <= 0:
        return 0
    if lam > 60:
        return max(0, int(round(rng.gauss(lam, math.sqrt(lam)))))
    L, k, p = math.exp(-lam), 0, 1.0
    while True:
        p *= rng.random()
        if p <= L:
            return k
        k += 1


def simulate(ladder, price, n, hours, rate, rate_shape, new_rate, frac_below, sims=4000, seed=7):
    """P(all n units sold within hours), expected fraction sold."""
    ahead = sum(q for u, q in ladder if u <= price)  # equal price: older listings first
    rng = random.Random(seed)
    all_sold = 0
    sold_total = 0.0
    for _ in range(sims):
        lam = rng.gammavariate(rate_shape, rate / rate_shape) if rate > 0 else 0
        demand = _poisson(lam * hours, rng)
        undercut = _poisson(new_rate * hours * frac_below, rng) if new_rate else 0
        got = demand - ahead - undercut
        if got >= n:
            all_sold += 1
        sold_total += min(n, max(0, got))
    return all_sold / sims, sold_total / sims / n, ahead


def fraction_below(ratios, price, cur_min):
    if not cur_min:
        return 0.7
    target = price / cur_min
    if sum(q for _, q in ratios) >= 5:
        total = sum(q for _, q in ratios)
        below = sum(q for r, q in ratios if r < target) + 0.5 * sum(q for r, q in ratios if r == target)
        return below / total
    return 0.5 if price <= cur_min else 0.85


def recommend(market, key, hours, conf, qty, cost=None, mode='all', rate_per_day=None):
    view = market.current(key)
    dem = market.demand(key)
    out = {'view': view, 'demand': dem, 'rows': [], 'pick': None}
    if not view['ladder'] or not view['min']:
        return out
    if rate_per_day is not None:  # your own assumption: wide uncertainty
        rate, shape = rate_per_day / 24, 1.0
    else:
        rate = dem['mid'] or 0
        shape = max(0.7, min(12.0, (dem['cover'] or 0) / 6))
    ladder = sorted(view['ladder'])
    cur_min = view['min']
    candidates = set()
    for u, _ in ladder[:12]:
        candidates.add(max(1, u - 1))
    candidates.add(max(1, cur_min - 1))
    for f in (0.9, 0.95, 0.97):
        candidates.add(max(1, int(cur_min * f)))
    if cost:
        candidates.add(int(math.ceil(cost / (1 - AH_CUT))))
    # new listings (competition) per hour: measured when there is enough data, else as many as are bought
    measured = (dem['cover'] or 0) >= MIN_COVER_H
    new_rate = (dem['newRate'] or 0) if measured else rate
    ratios = dem['newRatios'] if measured else []
    rows = []
    for p in sorted(candidates):
        frac = fraction_below(ratios, p, cur_min)
        p_all, e_frac, ahead = simulate(ladder, p, qty, hours, rate, shape, new_rate, frac)
        revenue = e_frac * qty * p * (1 - AH_CUT)
        profit = revenue - e_frac * qty * cost if cost else None
        rows.append({'price': p, 'ahead': ahead, 'pAll': p_all, 'eFrac': e_frac, 'revenue': revenue, 'profit': profit})
    out['rows'] = rows
    metric = 'pAll' if mode == 'all' else 'eFrac'
    ok = [r for r in rows if r[metric] >= conf and (cost is None or r['price'] * (1 - AH_CUT) >= cost)]
    out['pick'] = max(ok, key=lambda r: r['price']) if ok else None
    return out

# --------------------------------------------------------------------------- commands


def cmd_summary(m, args):
    print('Data: %s  (saved %s ago)' % (m.sv_path, ago(m.saved_at)))
    print('Realm: %s   items tracked: %d   watched: %d' % (m.realm_key, len(m.items), len(m.watch)))
    deep = [s for s in m.scans if s[0].startswith('r')]
    browse = [s for s in m.scans if s[0].startswith('b')]
    print('Scans stored: %d deep, %d Auctionator' % (len(deep), len(browse)))
    rows = []
    for s in m.scans[-12:]:
        t = stamp_to_epoch(s[0][1:])
        rows.append([when(t), 'deep' if s[0][0] == 'r' else 'auctionator', s[1] if len(s) > 1 else '',
                     b36(s[2]) or '' if len(s) > 2 else '', b36(s[3]) or '' if len(s) > 3 else '',
                     (b36(s[8]) or 0) if len(s) > 8 and s[8] else '', money(b36(s[6])) if len(s) > 6 else ''])
    table(rows, ['when', 'type', 'src', 'auctions', 'items', 'sold~', 'gold'])
    gold = [g.split(',') for g in as_list(m.r.get('gold'))]
    if gold:
        print('\nGold (last entries):')
        for g in gold[-6:]:
            print('  %s  %-12s %s' % (when(stamp_to_epoch(g[0])), g[1], money(b36(g[2]))))


def cmd_item(m, args):
    for key in m.find(args.query)[:3]:
        print('=' * 78)
        print('%s  [%s]  %s' % (m.name(key), key, '(watched: %s)' % m.watch[key] if key in m.watch else ''))
        if m.has_variants(key):
            print('Random suffix item: "of Spirit", "of the Eagle"... share this key, so prices mix variants of different value')
        view = m.current(key)
        dem = m.demand(key)
        print('Now: %s, %s listed  (%s, %s ago%s)' % (money(view['min']), view['qty'], view['source'], ago(view['t']),
              ', ladder approximated' if view['approx'] else ''))
        if dem['mid'] is not None:
            print('Bought: %.1f/day (range %.1f-%.1f), new listings %.1f/day, coverage %.1fh in %d intervals' % (
                dem['mid'] * 24, (dem['low'] or 0) * 24, (dem['high'] or 0) * 24, (dem['newRate'] or 0) * 24,
                dem['cover'], dem['intervals']))
        elif dem['cover']:
            print('Bought: not enough data yet (%.1fh of usable scan intervals, needs %.0fh%s)' % (
                dem['cover'], MIN_COVER_H, '; %d interval(s) over 8h skipped' % dem['longSkipped'] if dem['longSkipped'] else ''))
        else:
            print('Bought: unknown yet (needs deep scans or searches of this item at most 8h apart)')
        if view['ladder']:
            print('Ladder: ' + '  '.join('%s x%d' % (money(u), q) for u, q in sorted(view['ladder'])[:10]))
        vendor = m.vendor_price(key)
        if vendor:
            print('Vendor sells it for: %s' % money(vendor))
        recs = m.records(key)[-args.rows:]
        if recs:
            rows = []
            for r in recs:
                if r['kind'] == 'b':
                    rows.append([when(r['t']), 'auc', money(r['min']), r['qty'], '', '', '', '', ''])
                else:
                    rows.append([when(r['t']), 'deep' + ('=' if r.get('unchanged') else ''), money(r['min']), r['qty'],
                                 r.get('own') or '', '%dm' % r['gap'] if r.get('gap') else '', r['sold'] or '', r['amb'] or '',
                                 '%s@%s' % (r['new'], money(r['newMin'])) if r['new'] else ''])
            table(rows, ['when', 'src', 'min', 'qty', 'yours', 'gap', 'sold', 'sold?', 'new'])
        searches = m.searches(key)[-6:]
        if searches:
            print('Searches:')
            for s in searches:
                extra = ' | %dm: sold %d, reposted %d, new %d' % (s['gap'], s['sold'], s['rep'], s['new']) if s.get('gap') else ''
                print('  %s %s%s  %s%s' % (when(s['t']), s['kind'], '' if s['full'] else ' (partial)',
                      '  '.join('%s x%d' % (money(u), q) for u, q in s['ladder'][:6]), extra))
        roll = m.rollups(key)[-10:]
        if roll:
            print('Daily (older than 72h):')
            for d in roll:
                print('  %s  min %s avg %s  qty~%d  sold %d (+%d?)' % (time.strftime('%d.%m.', time.gmtime(d['date'])),
                      money(d['minMin']), money(d['avgMin']), d['avgQty'], d['sold'], d['amb']))
        hist = m.auctionator().get(key)
        if hist and args.history:
            day0 = auctionator_day0()
            print('Auctionator daily history:')
            days = sorted(int(d) for d in (hist.get('h') or {}))
            for d in days[-14:]:
                h = hist.get('h', {}).get(str(d))
                lo = (hist.get('l') or {}).get(str(d)) if isinstance(hist.get('l'), dict) else None
                a = (hist.get('a') or {}).get(str(d))
                print('  %s  low %s  high %s  qty %s' % (time.strftime('%d.%m.', time.localtime(day0 + d * 86400)),
                      money(lo), money(h), a))


def auctionator_day0():
    return time.mktime((2020, 1, 1, 0, 0, 0, 0, 0, -1))


def cmd_price(m, args):
    keys = m.find(args.query)
    if not keys:
        sys.exit('Item not found: %s' % args.query)
    key = keys[0]
    cost = parse_money(args.cost) if args.cost else None
    res = recommend(m, key, args.hours, args.conf, args.qty, cost, args.mode, args.rate)
    view, dem = res['view'], res['demand']
    print('%s [%s]: now %s, %s listed (%s, %s ago)' % (m.name(key), key, money(view['min']), view['qty'],
          view['source'], ago(view['t'])))
    if args.rate is not None:
        print('Demand assumed: %.1f/day (--rate)' % args.rate)
    elif dem['mid'] is None:
        print('Demand unknown: needs %.0fh of deep scans (or searches) at most 8h apart, has %.1fh.' % (
            MIN_COVER_H, dem['cover'] or 0))
        print('Give your own estimate with --rate <sold per day> (e.g. from: sales) to simulate anyway.')
        return
    else:
        print('Demand ~%.1f/h (%.1f/day), new listings ~%.1f/day, coverage %.1fh' % (
            dem['mid'], dem['mid'] * 24, (dem['newRate'] or 0) * 24, dem['cover']))
    if not res['rows']:
        print('No market data for this item.')
        return
    rows = []
    for r in res['rows']:
        rows.append([money(r['price']), r['ahead'], '%.0f%%' % (r['pAll'] * 100), '%.0f%%' % (r['eFrac'] * 100),
                     money(r['revenue']), money(r['profit']) if r['profit'] is not None else ''])
    table(rows, ['price', 'cheaper', 'P(all %d sold %dh)' % (args.qty, args.hours), 'E[sold]', 'E[revenue]', 'E[profit]'])
    pick = res['pick']
    if pick:
        print('\nPick: %s  (P(all)=%.0f%%, expected %.0f%% sold within %dh)' % (money(pick['price']), pick['pAll'] * 100,
              pick['eFrac'] * 100, args.hours))
    else:
        print('\nNo price reaches %.0f%% %s within %dh%s.' % (args.conf * 100, 'all sold' if args.mode == 'all' else 'sold',
              args.hours, ' above cost' if cost else ''))
    if view.get('approx'):
        print('(ladder approximated from summary stats: /fm watch the item for exact depth)')


def cmd_movers(m, args):
    rows = []
    for key in m.items:
        recs = [r for r in m.records(key) if r.get('min')]
        if len(recs) < 2:
            continue
        last = recs[-1]
        if last['t'] < m.now - 36 * 3600:
            continue
        # the record closest to 24h before the last one, at least 12h older
        older = [r for r in recs if r['t'] <= last['t'] - 12 * 3600]
        if not older:
            continue
        old = min(older, key=lambda r: abs(last['t'] - 24 * 3600 - r['t']))
        change = last['min'] / old['min'] - 1
        dem = m.demand(key, hours=48)
        per_day = dem['mid'] * 24 if dem['mid'] is not None else None
        turnover = per_day * last['min'] if per_day is not None else None
        rows.append((key, change, last, old, per_day, turnover))
    traded = [r for r in rows if r[5] is not None]
    print('Most traded (estimated copper turnover per day):')
    if traded:
        best = sorted(traded, key=lambda r: -r[5])[:args.top]
        table([[m.name(k)[:30], money(l['min']), l['qty'], '%.0f' % pd, money(t), '%+.0f%%' % (c * 100)]
               for k, c, l, o, pd, t in best], ['item', 'min', 'listed', 'sold/day', 'turnover/day', 'price'])
    else:
        print('  not enough data yet: sales rates need %.0fh of deep scans at most 8h apart' % MIN_COVER_H)
    print('\nBiggest price moves (now vs. ~24h before, at least 12h):')
    moves = sorted([r for r in rows if min(r[2]['qty'] or 0, r[3]['qty'] or 0) >= 3], key=lambda r: -abs(r[1]))[:args.top]
    table([[m.name(k)[:30], when(o['t']), money(o['min']), money(l['min']), '%+.0f%%' % (c * 100), o['qty'], l['qty'],
            '%.0f' % pd if pd is not None else '?']
           for k, c, l, o, pd, t in moves], ['item', 'before at', 'before', 'now', 'change', 'qty before', 'qty now', 'sold/day'])


def parse_invoice(f):
    """stamp,char,type,item,player,qty,bid,buyout,deposit,cut. On Forever "bid" is the money of the sale
    (the total) and "buyout" holds the quantity for commodity sales, so the total is bid."""
    def num(i):
        return (b36(f[i]) or 0) if len(f) > i and f[i] else 0
    qty = num(5) or 1
    total = num(6) or num(7)
    cut = num(9)
    return {'t': stamp_to_epoch(f[0]), 'char': f[1] if len(f) > 1 else '', 'type': f[2] if len(f) > 2 else '',
            'name': fix_text(f[3]) if len(f) > 3 else '', 'qty': qty, 'total': total, 'cut': cut, 'net': total - cut}


def split_count(name):
    """'Feathered Arrow (200)' -> ('Feathered Arrow', 200); 'Insignia Cap' -> ('Insignia Cap', None)"""
    match = re.match(r'^(.*?) \((\d+)\)$', name or '')
    return (match.group(1), int(match.group(2))) if match else (name or '', None)


def weighted_median(pairs):
    """[(value, weight), ...] sorted by value -> weighted median or None"""
    total = sum(w for _, w in pairs)
    if not total:
        return None
    acc = 0
    for value, w in pairs:
        acc += w
        if acc >= total / 2:
            return value
    return pairs[-1][0]


def match_sales(m, days):
    """Your posts matched FIFO per item with what happened to them: sale invoices and sold auctions,
    cancelled auctions / mails, expired mails. Returns (posts, unmatched invoices, all invoices)."""
    since = m.now - days * 86400
    posts = []
    for f in (p.split(',') for p in as_list(m.r.get('posts'))):
        if len(f) < 7:
            continue
        t = stamp_to_epoch(f[0])
        if t < since:
            continue
        posts.append({'t': t, 'char': f[1], 'key': f[2], 'qty': b36(f[3]) or 1, 'unit': b36(f[4]) or 0,
                      'hours': POST_HOURS.get(f[5], 24), 'kind': f[6], 'sold': 0, 'exp': 0, 'can': 0,
                      'waits': [], 'net': 0.0})
    by_key = {}
    for p in posts:
        by_key.setdefault(p['key'], []).append(p)
    names = {k: m.name(k).lower() for k in by_key}

    def key_for(name):
        low = (name or '').lower()
        best = None
        for k, n in names.items():
            if low == n:
                return k
            if low.startswith(n + ' ') and (best is None or len(n) > len(names[best])):
                best = k  # random suffix gear: "Sentinel Gloves of the Falcon"
        return best

    def allocate(key, qty, t, field, net=None, fits=None):
        for p in by_key.get(key, []):
            if qty <= 0:
                break
            if p['t'] > t + 600 or post_rest(p) <= 0 or (fits and not fits(p)):
                continue
            take = min(post_rest(p), qty)
            p[field] += take
            if field == 'sold':
                p['waits'].append((max(0.0, (t - p['t']) / 3600), take))
                p['net'] += net * take if net is not None else take * p['unit'] * (1 - AH_CUT)
            qty -= take
        return qty

    invoices = [parse_invoice(i.split(',')) for i in as_list(m.r.get('invoices'))]
    invoices = [i for i in invoices if i['t'] >= since - 3600]
    seller = sorted([i for i in invoices if i['type'] == 'seller'], key=lambda i: i['t'])
    unmatched, invoiced = {}, {}
    for inv in seller:
        key = key_for(inv['name'])
        left = allocate(key, inv['qty'], inv['t'], 'sold', inv['net'] / inv['qty']) if key else inv['qty']
        if key:
            invoiced[key] = invoiced.get(key, 0) + inv['qty']
        if left > 0:
            u = unmatched.setdefault(inv['name'], [0, 0])
            u[0] += left
            u[1] += inv['net'] * left / inv['qty']

    events = [f for f in (e.split(',') for e in as_list(m.r.get('events')))
              if len(f) >= 3 and stamp_to_epoch(f[0]) >= since]
    events.sort(key=lambda f: stamp_to_epoch(f[0]))
    # sold auctions seen at the AH whose mail was not read yet (beyond what the invoices cover)
    seen_sold = {}
    for f in events:
        if f[2] in ('osold', 'opart') and len(f) >= 5:
            seen_sold.setdefault(f[3], []).append((stamp_to_epoch(f[0]), b36(f[4]) or 1))
    for key, sales in seen_sold.items():
        extra = sum(q for _, q in sales) - invoiced.get(key, 0)
        for t, q in sales:
            if extra <= 0:
                break
            take = min(q, extra)
            allocate(key, take, t, 'sold')
            extra -= take
    # cancelled: your auctions first, cancel mails only beyond those
    cancelled = {}
    for f in events:
        if f[2] == 'ocancel' and len(f) >= 5:
            q = b36(f[4]) or 1
            cancelled[f[3]] = cancelled.get(f[3], 0) + q
            allocate(f[3], q, stamp_to_epoch(f[0]), 'can')
    for f in events:
        if f[2] not in ('mexpired', 'mcancelled') or len(f) < 4:
            continue
        name, count = split_count(fix_text(f[3]))
        key = key_for(name)
        if not key:
            continue
        t = stamp_to_epoch(f[0])
        if f[2] == 'mcancelled':
            if cancelled.get(key, 0) > 0:  # the same cancel, seen at the AH already
                cancelled[key] -= count or 1
            else:
                allocate(key, count or 1, t, 'can')
            continue

        def ran_out(p, t=t):  # an expired auction ran its full time before the mail
            return p['t'] + p['hours'] * 3600 <= t + 2 * 3600
        if count is None:
            first = next((p for p in by_key.get(key, []) if post_rest(p) > 0 and ran_out(p)), None)
            count = 1 if not first or first['kind'] == 'i' else post_rest(first)
        allocate(key, count, t, 'exp', fits=ran_out)
    return posts, unmatched, invoices


def post_rest(p):
    return p['qty'] - p['sold'] - p['exp'] - p['can']


def cmd_sales(m, args):
    posts, unmatched, invoices = match_sales(m, args.days)
    by_key = {}
    for p in posts:
        by_key.setdefault(p['key'], []).append(p)
    print('Your sales in the last %d days (posts matched with mails and your auctions):' % args.days)
    rows = []
    for key, plist in sorted(by_key.items(), key=lambda kv: -sum(p['qty'] for p in kv[1])):
        posted = sum(p['qty'] for p in plist)
        sold = sum(p['sold'] for p in plist)
        exp = sum(p['exp'] for p in plist)
        can = sum(p['can'] for p in plist)
        listed = sum(post_rest(p) for p in plist if m.now < p['t'] + p['hours'] * 3600)
        unknown = posted - sold - exp - can - listed
        net = sum(p['net'] for p in plist)
        wait = weighted_median(sorted(w for p in plist for w in p['waits']))
        ended = sold + exp + can + unknown
        rows.append([m.name(key)[:28], posted, sold, exp, can, listed, unknown,
                     '%.0f%%' % (100 * sold / ended) if ended else '',
                     money(net / sold) if sold else '', money(net) if sold else '', '%.1fh' % wait if wait is not None else ''])
    table(rows, ['item', 'posted', 'sold', 'expired', 'cancel', 'listed', 'unknown', 'sold%', 'net/unit', 'net', 'sold after'])
    print('  unknown = ended while you were away and its mail was not read yet (sold or expired)')
    if unmatched:
        print('\nSold, but the post was not logged (posted before the AddOn or by another character):')
        for name, (q, net) in sorted(unmatched.items(), key=lambda kv: -kv[1][1]):
            print('  %-28s x%-4d net %s' % (name[:28], q, money(net)))

    print('\nYour posts (latest %d):' % args.rows)
    rows = []
    for p in posts[-args.rows:]:
        open_now = m.now < p['t'] + p['hours'] * 3600
        state = ['%d %s' % (p[f], label) for f, label in (('sold', 'sold'), ('exp', 'expired'), ('can', 'cancelled')) if p[f]]
        if post_rest(p):
            state.append('%d %s' % (post_rest(p), 'listed' if open_now else 'unknown'))
        wait = weighted_median(sorted(p['waits']))
        rows.append([when(p['t']), m.name(p['key'])[:28], p['qty'], money(p['unit']), '%dh' % p['hours'],
                     ', '.join(state), '%.1fh' % wait if wait is not None else ''])
    table(rows, ['posted', 'item', 'qty', 'unit', 'time', 'result', 'sold after'])

    seller = [i for i in invoices if i['type'] == 'seller']
    if seller:
        print('\nSale invoices (mail, time = when the mail was sent):')
        for i in sorted(seller, key=lambda i: i['t'])[-args.rows:]:
            print('  %s  %-28s x%-4s %s  (net %s)' % (when(i['t']), i['name'][:28], i['qty'], money(i['total']), money(i['net'])))
        print('  net total: %s' % money(sum(i['net'] for i in seller)))
    bought = [i for i in invoices if i['type'] == 'buyer']
    if bought:
        print('\nYour purchases (mail):')
        agg = {}
        for i in bought:
            a = agg.setdefault(i['name'], [0, 0])
            a[0] += i['qty']
            a[1] += i['total']
        for name, (q, total) in sorted(agg.items(), key=lambda kv: -kv[1][1]):
            print('  %-28s x%-5d %s  (%s each)' % (name[:28], q, money(total), money(total / q)))


def load_reagent_dbs(sv_dir, prof):
    out = []
    for path in glob.glob(os.path.join(sv_dir, 'ForeverArtisan_%s.lua' % (prof or '*'))):
        name = os.path.basename(path)[len('ForeverArtisan_'):-4]
        if name in ('Core', 'Contacts', 'Camping'):
            pass
        try:
            sv = load_saved_variables(path)
        except Exception:
            continue
        for gname, db in sv.items():
            if not isinstance(db, dict) or 'chars' not in db:
                continue
            for char, data in (db.get('chars') or {}).items():
                recipes = (data or {}).get('recipes') or {}
                out.append((name, char, data.get('skill'), recipes))
    return out


def cmd_craft(m, args):
    dbs = load_reagent_dbs(m.sv_dir, args.prof)
    if not dbs:
        sys.exit('No ForeverArtisan profession data found.')
    vendor_buy = {}
    m.auctionator()
    for k, v in getattr(m, 'vendor', {}).items():
        vendor_buy[str(k)] = v
    rows = []
    for prof, char, skill, recipes in dbs:
        for rname, r in recipes.items():
            if not isinstance(r, dict) or (not r.get('learned') and not args.all):
                continue
            product = str(r.get('itemId') or '')
            pv = m.current(product)
            if not pv['min']:
                hist = m.auctionator().get(product)
                if not hist or not hist.get('m'):
                    continue
                pv = {'min': hist['m'], 'qty': '(auc)'}
            cost, missing = 0, []
            for reagent in as_list(r.get('reagents')):
                rid = str(reagent.get('id'))
                n = reagent.get('n') or 1
                price = vendor_buy.get(rid)
                if price is None:
                    price = m.current(rid)['min']
                if price is None:
                    hist = m.auctionator().get(rid)
                    price = hist.get('m') if hist else None
                if price is None:
                    missing.append(fix_text(reagent.get('name') or rid))
                    continue
                cost += price * n
            if missing:
                continue
            makes = r.get('makes') or 1
            revenue = pv['min'] * makes * (1 - AH_CUT)
            dem = m.demand(product, hours=72)
            per_day = (dem['mid'] or 0) * 24
            rows.append([fix_text(rname)[:32], prof[:4], money(cost), money(pv['min']), money(revenue - cost),
                         '%.0f' % per_day if dem['mid'] is not None else '?', pv['qty'], r.get('grayAt') or '',
                         revenue - cost])
    rows.sort(key=lambda r: -r[-1])
    print('Crafting margins (product min price, 5% cut, reagents at vendor or AH min):')
    table([r[:-1] for r in rows[:args.top]], ['recipe', 'prof', 'cost', 'sells', 'profit', 'sold/day', 'listed', 'gray'])

# --------------------------------------------------------------------------- flips


def latest_gold(m):
    gold = [g.split(',') for g in as_list(m.r.get('gold'))]
    for g in reversed(gold):
        value = b36(g[2]) if len(g) > 2 else None
        if value:
            return value
    return None


def daily_prices(m, key, auc, today, days=8):
    """One lowest price per day for the last days (today excluded): our scans of that day (median of their
    minimums) or else Auctionator's daily low/high. Returns [(day, price)] in Auctionator day numbers."""
    day0 = auctionator_day0()
    ours = {}
    for r in m.records(key):
        if r.get('min'):
            d = int((r['t'] - day0) // 86400)
            if today - days <= d < today:
                ours.setdefault(d, []).append(r['min'])
    hist = auc.get(key) or {}
    highs, lows = hist.get('h') or {}, hist.get('l') if isinstance(hist.get('l'), dict) else {}
    out = []
    for d in range(today - days, today):
        if d in ours:
            values = sorted(ours[d])
            out.append((d, values[len(values) // 2]))
        else:
            candidates = [v for v in (highs.get(str(d)), lows.get(str(d))) if v]
            if candidates:
                out.append((d, min(candidates)))
    return out


def usual_price(m, key, auc, today):
    """Median of the daily lowest prices of the last week and of the last two days, or (None, None)
    without 3 days of history."""
    daily = daily_prices(m, key, auc, today)
    if len(daily) < 3:
        return None, None
    values = sorted(v for _, v in daily)
    recent = sorted(v for d, v in daily if d >= today - 2)
    return values[len(values) // 2], (recent[len(recent) // 2] if recent else None)


def cmd_flips(m, args):
    """Cheap listings well below the usual price, with a real market (not one odd listing) above them:
    buy them, list them again just under that market."""
    budget = parse_money(args.budget) if args.budget else (latest_gold(m) or 100000)
    auc = m.auctionator()
    today = int((time.time() - auctionator_day0()) // 86400)
    rows = []
    for key in m.items:
        view = m.current(key)
        if not view['min'] or not view['ladder'] or not view['t'] or m.now - view['t'] > args.max_age * 3600:
            continue
        if (view['qty'] or 0) < 5 or m.has_variants(key):
            continue  # thin market, or random suffix variants whose prices cannot be compared
        ref, recent = usual_price(m, key, auc, today)
        if not ref or ref < args.min_price:
            continue
        if recent and not 0.8 * ref <= recent <= 1.25 * ref:
            continue  # the price moved for days: a new level, not a bargain
        ladder = sorted(view['ladder'])
        if view['source'] == 'deep' and not view['approx']:
            ladder = m.last_scan_ladder(key, view['t'], skip_own=True) or ladder  # you cannot buy your own
        limit = ref * args.below
        cheap = [(u, q) for u, q in ladder if u <= limit]
        above = [(u, q) for u, q in ladder if u > limit]
        if not cheap or not above:
            continue
        if sum(q for _, q in cheap) > 0.25 * view['qty']:
            continue  # most of the market is that cheap now: the price dropped, it is not a bargain
        # list just under the first price where real stock waits (at least 3 units / 10% of the market)
        need = max(3, 0.1 * view['qty'])
        acc, wall = 0, None
        for u, q in above:
            acc += q
            if acc >= need:
                wall = u
                break
        if wall is None or wall < 0.85 * ref:
            continue
        support = sum(q for u, q in above if u <= wall)
        sell = min(int(ref * 1.1), wall) - 1
        units = cost = top_unit = 0
        cap = support if view['approx'] else max(support, 5)
        for u, q in cheap:
            n = min(q, cap - units, int((budget - cost) // u))
            if n <= 0:
                break
            units += n
            cost += n * u
            top_unit = u
        if not units:
            continue
        profit = units * sell * (1 - AH_CUT) - cost
        if profit < args.min_profit:
            continue
        dem = m.demand(key)
        rows.append({'key': key, 'units': units, 'cheapQty': sum(q for _, q in cheap), 'cost': cost, 'top': top_unit,
                     'sell': sell, 'profit': profit, 'ref': ref, 'qty': view['qty'], 'approx': view['approx'],
                     't': view['t'], 'perDay': dem['mid'] * 24 if dem['mid'] is not None else None})
    rows.sort(key=lambda r: -r['profit'])
    print('Flips: listings at most %.0f%% of the usual price, budget %s, data up to %.0fh old' % (
        args.below * 100, money(budget), args.max_age))
    if not rows:
        print('  nothing found')
        return
    table([[m.name(r['key'])[:28], money(r['top']), '%d/%d' % (r['units'], r['cheapQty']), money(r['cost']),
            money(r['sell']), money(r['profit']), '%.0f%%' % (100 * r['profit'] / r['cost']), money(r['ref']), r['qty'],
            '%.0f' % r['perDay'] if r['perDay'] is not None else '?', ago(r['t']) + ('~' if r['approx'] else '')]
           for r in rows[:args.top]],
          ['item', 'buy up to', 'units', 'cost', 'list at', 'profit', 'ROI', 'usual', 'listed', 'sold/day', 'age'])
    print('  usual = median daily lowest price of the last week; units = to buy / cheap ones listed (capped at')
    print('  the stock already waiting at the list price); ~ = ladder approximated')
    print('  cheap listings go fast: check with an AH search before buying; deposits are lost if it does not sell')


# --------------------------------------------------------------------------- room (Picks' cap against your sales)

PICKS_WINDOW = 72 * 3600  # Picks reads 3 days of deep scans and of your sales
PICKS_SHARE_OF_BUYERS = 0.5  # trade/Picks.lua SHARE_OF_BUYERS until 1.39 (FRV-103 replaced the rate with the batch)
PICKS_OWN_MIN = 3  # your own record counts from 3 units sold in the window


def picks_buyers(m, key, now):
    """Buyers per day as Picks counts them (trade/Picks.lua Demand): units gone at or under the cheapest auction
    still listed (soldLow) over intervals of at most 8h in the last 3 days, relist bursts capped, records before
    soldLow at 0.3 of what vanished. Returns (per day or None below 2h of intervals, trusted)"""
    since = now - PICKS_WINDOW
    bought = cover = 0.0
    intervals = auctions = 0
    prev_qty = None
    for rec in m.records(key):
        if rec['kind'] != 'r':
            continue
        gap = rec.get('gap')
        if rec['t'] and since < rec['t'] <= now and gap and 0 < gap <= CLEAN_GAP_MIN:
            cover += gap
            if not rec.get('unchanged'):
                sold = rec.get('sold') or 0
                units = rec.get('soldLow')
                if units is None:
                    units = sold * 0.3
                # relist burst: a big share of the listings gone while about as many came back
                if prev_qty and sold > 0.3 * prev_qty and (rec.get('new') or 0) >= 0.5 * sold:
                    units = min(units, 0.15 * prev_qty)
                if units > 0:
                    bought += units
                    intervals += 1
                    auctions += rec.get('soldN') or 0
        prev_qty = rec.get('qty') or 0
    if cover < MIN_COVER_H * 60:
        return None, False
    return bought / cover * 1440, intervals >= 3 and auctions >= 5


def picks_circulation(m, key, now):
    """C/24h as the market table shows it (trade/Calc.lua SoldLatest x 2): sold plus half the ambiguous units over
    intervals of at most 8h in the last 12h, or the last 3 days when 12h has under 2h of them"""
    for window in (12 * 3600, PICKS_WINDOW):
        sold = cover = 0.0
        for rec in m.records(key):
            gap = rec.get('gap')
            if rec['kind'] == 'r' and rec['t'] and now - window < rec['t'] <= now and gap and 0 < gap <= CLEAN_GAP_MIN:
                cover += gap
                if not rec.get('unchanged'):
                    sold += (rec.get('sold') or 0) + 0.5 * (rec.get('amb') or 0)
        if cover >= MIN_COVER_H * 60:
            return sold * 1440 / cover
    return None


def own_listings(m, now):
    """Your listings per item as Picks counts them (FM.OwnListings): each character's last auction list (running
    auctions) plus the posts after it that still run. Returns {key: {'list', 'posts', 'seen'}} and the newest list"""
    out, since, in_list, newest = {}, {}, {}, None

    def add(key, qty, field, seen):
        e = out.setdefault(key, {'list': 0, 'posts': 0, 'seen': seen})
        e[field] += qty
        e['seen'] = min(e['seen'], seen)

    for char, snap in (m.r.get('owned') or {}).items():
        if not isinstance(snap, dict) or not snap.get('t'):
            continue
        since[char] = snap['t']
        newest = max(newest or 0, snap['t'])
        aids = in_list.setdefault(char, set())
        for entry in (snap.get('list') or '').split(','):
            f = entry.split(':')  # aid:key:qty:buyout:status:left
            if len(f) < 6 or not f[0]:
                continue
            aids.add(f[0])
            left = b36(f[-1]) or 0
            if f[-2] != 's' and snap['t'] + (left if left > 0 else 86400) > now:
                add(':'.join(f[1:-4]), b36(f[-4]) or 1, 'list', snap['t'])
    for post in as_list(m.r.get('posts')):
        f = post.split(',')
        t = stamp_to_epoch(f[0])
        if not t or len(f) < 6 or now - t > 86400:
            continue
        list_t = since.get(f[1])
        after = list_t is None or t >= list_t - 60
        if after and len(f) > 7 and f[7] in in_list.get(f[1], ()):
            after = False  # a post of the same minute as the list, already in it
        if after and now < t + POST_HOURS.get(f[5], 24) * 3600:
            add(f[2], b36(f[3]) or 1, 'posts', t)
    return out, newest


def listed_spans(m, since, now):
    """Per item: the time its posts ran in the window (by their duration) and whether it is a commodity"""
    spans, kinds = {}, {}
    for post in as_list(m.r.get('posts')):
        f = post.split(',')
        t = stamp_to_epoch(f[0])
        if not t or len(f) < 6:
            continue
        end = min(t + POST_HOURS.get(f[5], 24) * 3600, now)
        if end > since and t < now:
            spans.setdefault(f[2], []).append((max(t, since), end))
            kinds[f[2]] = 'commodity' if len(f) > 6 and f[6] == 'c' else 'item'
    return spans, kinds


def span_hours(spans):
    """Hours covered by overlapping (start, end) spans"""
    total, cur = 0.0, None
    for a, b in sorted(spans):
        if cur and a <= cur[1]:
            cur[1] = max(cur[1], b)
        else:
            if cur:
                total += cur[1] - cur[0]
            cur = [a, b]
    if cur:
        total += cur[1] - cur[0]
    return total / 3600


def cmd_room(m, args):
    """Picks' room on the AH (FRV-55) against your own sales: your listings as Picks counts them, C/24h, the cap,
    and how many you really sold per day while you had the item listed (FRV-56)"""
    now = m.saved_at  # the data ends when the game saved it
    since = now - args.days * 86400
    pct = args.share if args.share is not None else (m.settings.get('tableCircPct') or 25)
    share = pct / 100.0
    listings, newest = own_listings(m, now)
    spans, kinds = listed_spans(m, since, now)
    names = {n: k for k, n in m.names.items()}
    sold, sold3, first_post = {}, {}, {}
    for line in as_list(m.r.get('invoices')):
        f = line.split(',')
        if len(f) < 7 or f[2] != 'seller':
            continue
        t, key = stamp_to_epoch(f[0]), names.get(fix_text(f[3]))
        if key and t and since <= t <= now:
            sold[key] = sold.get(key, 0) + (b36(f[5]) or 1)
    for post in as_list(m.r.get('posts')):
        f = post.split(',')
        t = stamp_to_epoch(f[0])
        if t and len(f) > 2 and now - PICKS_WINDOW < t <= now and (f[2] not in first_post or t < first_post[f[2]]):
            first_post[f[2]] = t
    # Picks' own rate until 1.39 counted each sale once (OwnSales in trade/Picks.lua, FRV-109): an osold line written again (the
    # same character, auction, units, price and nth; a sold row's line with its mail time only when an earlier line's
    # mail time is within 2 minutes of its own, FRV-118, an earlier one without a mail time within 61 minutes of it;
    # a line without a mail time until the mail time of the newest earlier one, else within 61 minutes of it) counts
    # nothing, nor does one without "s" of an auction that is in the newest list after all with more units than were
    # posted (the Profit tab's rule, Repeats in scan/Worth.lua)
    posted, listed, logged = {}, {}, {}
    for post in as_list(m.r.get('posts')):
        f = post.split(',')
        if len(f) > 7 and f[7]:
            posted[f[7]] = b36(f[3]) or 1
    for snap in (m.r.get('owned') or {}).values():
        if isinstance(snap, dict):
            for entry in (snap.get('list') or '').split(','):
                f = entry.split(':')  # aid:key:qty:buyout:status:left
                if len(f) >= 6 and f[0]:
                    listed[f[0]] = listed.get(f[0], 0) + (b36(f[-4]) or 1)
    for e in as_list(m.r.get('events')):
        f = e.split(',')
        t = stamp_to_epoch(f[0])
        if len(f) > 4 and f[2] in ('osold', 'opart'):
            qty, counts = b36(f[4]) or 1, True
            aid = f[6] if len(f) > 6 else ''
            if f[2] == 'osold' and aid:
                shown = len(f) > 8 and f[8] == 's'
                ident = (f[1], aid, f[4], f[5] if len(f) > 5 else '', f[9] if len(f) > 9 else '')
                mail = stamp_to_epoch(f[10]) if len(f) > 10 else None
                refs = logged.get(ident)
                if refs and shown and mail:
                    again = any(abs(ref[1] - mail) <= 120 if ref[1] else (t or 0) <= ref[0] + 61 * 60 for ref in refs)
                elif refs:
                    ref = refs[-1]
                    again = not (shown and t and t > (ref[1] + 60 if ref[1] else ref[0] + 61 * 60))
                else:
                    again = False
                if again:
                    counts = False
                else:
                    logged.setdefault(ident, []).append((t or 0, mail))
                there = not shown and listed.get(aid)
                if there and (aid not in posted or qty + there > posted[aid]):
                    counts = False
            if counts and t and now - PICKS_WINDOW < t <= now:
                sold3[f[3]] = sold3.get(f[3], 0) + qty
    keys = set(spans) | set(listings)
    if args.items:
        keys = {k for q in args.items for k in m.find(q)[:1]}
    print('Room on the AH as Picks plans it (%d%% of C/24h), data saved %s; your auction lists last read %s ago'
          % (pct, when(now), ago(newest, now) if newest else 'never'))
    rows, shares = [], {'item': [], 'commodity': []}
    for key in keys:
        circ = picks_circulation(m, key, now)
        buyers, trusted = picks_buyers(m, key, now)
        e = listings.get(key) or {'list': 0, 'posts': 0, 'seen': None}
        cap = int(circ * share + 0.5) if circ is not None else None
        hours = span_hours(spans.get(key, []))
        pace = sold.get(key, 0) / (hours / 24) if hours >= 6 else None
        of_circ = pace / circ if pace is not None and circ else None
        if of_circ is not None and sold.get(key, 0) >= 5:
            shares[kinds.get(key, 'item')].append(of_circ)
        units3 = sold3.get(key, 0)
        # Picks' own rate: sales of 3 days over the time since your first post in them (at least 12h)
        own_rate = (units3 / max(43200, now - first_post.get(key, now - PICKS_WINDOW)) * 86400
                    if units3 >= PICKS_OWN_MIN else None)
        rows.append([m.name(key)[:28], kinds.get(key, '?'), '%d+%d' % (e['list'], e['posts']),
                     ago(e['seen'], now) if e['seen'] else '-', '%.0f' % circ if circ is not None else '-',
                     cap if cap is not None else '-', cap - e['list'] - e['posts'] if cap is not None else '-',
                     sold.get(key, 0), '%.0f' % hours, '%.1f' % pace if pace is not None else '-',
                     '%.0f%%' % (of_circ * 100) if of_circ is not None else '-',
                     ('%.0f' % (buyers * PICKS_SHARE_OF_BUYERS) + ('' if trusted else '?')) if buyers is not None else '-',
                     '%.1f' % own_rate if own_rate is not None else '-'])
    rows.sort(key=lambda r: (-r[7], r[0]))
    table(rows, ['item', 'kind', 'listed', 'seen', 'C/24h', 'cap', 'room', 'sold', 'listed h', 'sold/day',
                 'of C/24h', 'buyers/2', 'pace 3d'])
    print('  listed = your auction lists + posts since (seen = the oldest of them); sold = sale mails of the last %d '
          'days; sold/day = per day you had it listed (posts by their duration)' % args.days)
    print('  buyers/2 = the market rate Picks planned with until 1.39 (? = too few intervals to trust it); pace 3d = '
          'your own rate as Picks read it until 1.39 (sales of 3 days over the time since your first post in them); '
          'since 1.40 Picks sizes a batch from your proven listings (FRV-103)')
    for kind, values in shares.items():
        if values:
            values.sort()
            print('  %s: you sold %.0f%% of C/24h per day listed at the median (%.0f%% - %.0f%%, %d with 5+ sold)'
                  % ({'item': 'items', 'commodity': 'commodities'}[kind], values[len(values) // 2] * 100,
                     values[0] * 100, values[-1] * 100, len(values)))


# --------------------------------------------------------------------------- your listings (FRV-125)
# `listings`: every post's outcome, the backtest in gold of the Picks batch (1.40, FRV-103) and the ranges of its
# constants, measured again on the days the saved variables hold; the plan log (R.plans) against what sold. The port
# of the analysis behind the formula (FRV-111, FRV-115; the Confluence page "ForeverMarket Picks: the formula"):
# https://envelopment.atlassian.net/wiki/spaces/~712020b06cd5a60c92413493fad43098103a66/pages/24182786
# ListingsBook is trade/Listings.lua's FM.ListingsRecord, rule for rule and in its minutes since EPOCH, so
# tests/tools/test_listings.py holds both to the same fixture (tests/fixtures/listings_cases.txt)

LST_WINDOW = 72 * 60       # minutes: your posts of the last 72 hours
LST_LONGEST = 24 * 60      # a 24h listing: posts this much before the window still run inside it
LST_SLACK = 15             # the clocks of mail stamps and list reads against the post's own
LST_EXPIRY_SLACK = 25      # an expiry mail of a commodity post goes out this close to the post's end
LST_PROVEN = 8 * 60        # "proven": what your listings sold within 8 hours of a post of yours
LST_GAP = 15               # nothing of yours listed for this long inside that time: your units ran out
# commodity posts before it were logged by older versions (no auction ID): the report leaves them out
LST_COMMODITY_FROM = time.mktime((2026, 11, 19, 12, 0, 0, 0, 0, -1))


def _split_count(name):
    """'Cured Thick Hide (23)' -> ('Cured Thick Hide', 23); 'Insignia Cap' -> ('Insignia Cap', None)"""
    m = re.match(r'^(.*?) \((\d+)\)$', name)
    return (m.group(1), int(m.group(2))) if m else (name, None)


def _by_time(x):
    return (x['t'], x['i'])


class ListingsBook:
    """Your listings and what each sold, at minute `now` (minutes since EPOCH): trade/Listings.lua. `since` = the
    first minute of the posts read (None: the AddOn's 72h window and the 24h before it). Each listing: i, t, finish,
    key, n, unit, hours, kind, aid, char, sold, times [(minute, units)], cancelled, expired, open"""

    def __init__(self, r, now, since=None, name_of=None):
        self.now = now
        since = now - LST_WINDOW - LST_LONGEST if since is None else since
        raw_names = r.get('names') or {}
        name_of = name_of or (lambda key: raw_names.get(key) or 'item:%s' % key)
        posts, by_key, names = [], {}, {}
        for i, line in enumerate(as_list(r.get('posts')), start=1):
            f = str(line).split(',')
            t = b36(f[0]) if f else None
            kind = f[6] if len(f) > 6 else None
            if t is not None and since < t <= now and len(f) > 2 and kind in ('i', 'c'):
                hours = POST_HOURS.get(f[5] if len(f) > 5 else '', 24)
                L = {'i': i, 't': t, 'char': f[1], 'key': f[2], 'n': b36(f[3]) or 1, 'unit': b36(f[4]) or 0,
                     'hours': hours, 'kind': kind, 'aid': f[7] if len(f) > 7 and f[7] else None, 'finish': t + hours * 60,
                     'sold': 0, 'times': [], 'cancelled': 0, 'expired': 0, 'open': False}
                posts.append(L)
                by_key.setdefault(L['key'], []).append(L)
                names.setdefault(L['key'], name_of(L['key']))
        posts.sort(key=_by_time)
        key_of = {name: key for key, name in names.items()}
        longest = sorted(names.values(), key=len, reverse=True)

        def key_of_name(name):
            if not isinstance(name, str):
                return None
            if name in key_of:
                return key_of[name]
            for n in longest:
                if name[:len(n) + 1] == n + ' ':
                    return key_of[n]
            return None

        sales = {}
        for i, line in enumerate(as_list(r.get('invoices')), start=1):
            f = str(line).split(',')
            t = b36(f[0]) if f else None
            if len(f) > 2 and f[2] == 'seller' and t is not None and t > since - LST_SLACK:
                key = key_of_name(f[3] if len(f) > 3 else None)
                if key:
                    sales.setdefault(key, []).append({'i': i, 't': t, 'qty': (b36(f[5]) if len(f) > 5 else None) or 1,
                                                      'total': (b36(f[6]) if len(f) > 6 else None) or 0})
        for lst in sales.values():
            lst.sort(key=_by_time)
        # the units of each auction in its character's newest list, and the units each auction was posted with
        in_list, posted, looked = {}, {}, {}
        for char, snap in (r.get('owned') or {}).items():
            if isinstance(snap, dict) and isinstance(snap.get('list'), str):
                for entry in [x for x in snap['list'].split(',') if x]:
                    f = entry.split(':')
                    if len(f) >= 6:
                        in_list[f[0]] = in_list.get(f[0], 0) + (b36(f[-4]) or 1)
            if isinstance(snap, dict) and isinstance(snap.get('t'), (int, float)):
                looked[char] = (snap['t'] - EPOCH) / 60
        for L in posts:
            if L['aid']:
                posted[L['aid']] = L['n']
        events, by_aid, expiries = {}, {}, {}
        for i, line in enumerate(as_list(r.get('events')), start=1):
            f = str(line).split(',')
            t = b36(f[0]) if f else None
            kind = f[2] if len(f) > 2 else None
            if t is None or t <= since:
                continue
            if kind in ('osold', 'opart', 'ocancel', 'ogone', 'oexpire'):
                e = {'i': i, 't': t, 'kind': kind, 'key': f[3] if len(f) > 3 else None,
                     'qty': (b36(f[4]) if len(f) > 4 else None) or 1, 'buyout': (b36(f[5]) if len(f) > 5 else None) or 0,
                     'aid': f[6] if len(f) > 6 and f[6] else None, 'prev': b36(f[7]) if len(f) > 7 else None}
                # an auction merely gone from a list that is in the newest one after all was not sold (FRV-109)
                there = kind == 'osold' and (f[8] if len(f) > 8 else None) != 's' and e['aid'] and in_list.get(e['aid'])
                if there and (e['aid'] not in posted or e['qty'] + there > posted[e['aid']]):
                    e['key'] = None
                if e['key'] and e['key'] in by_key:
                    events.setdefault(e['key'], []).append(e)
                    if e['aid']:
                        by_aid.setdefault(e['aid'], []).append(e)
            elif kind == 'mexpired' and len(f) > 3 and f[3]:
                name, count = _split_count(f[3])
                key = key_of_name(name)
                if key:
                    expiries.setdefault(key, []).append({'t': t, 'qty': count or 1})
        for lst in list(events.values()) + list(by_aid.values()):
            lst.sort(key=_by_time)
        self._items(posts, sales, events, now)
        self._commodities(posts, by_aid, expiries, looked)
        for L in posts:
            L['times'].sort(key=lambda m: m[0])
        self.listings, self.by_key = posts, by_key
        self._proven = {}

    @staticmethod
    def _mid(e):
        return ((e['prev'] if e['prev'] is not None else e['t']) + e['t']) / 2

    def _items(self, posts, sales, events, now):
        used = set()
        for L in posts:
            if L['kind'] != 'i':
                continue
            for s in sales.get(L['key'], []):
                if L['sold'] >= L['n']:
                    break
                if id(s) not in used and s['qty'] == 1 and abs(s['total'] - L['unit']) <= 0.5 \
                        and L['t'] - LST_SLACK <= s['t'] <= L['finish'] + LST_SLACK:
                    used.add(id(s))
                    L['sold'] += 1
                    L['times'].append((s['t'], 1))
        aid_used = set()
        for L in posts:
            if L['kind'] != 'i':
                continue
            sold_list, cancels, seen = [], [], set()
            for e in events.get(L['key'], []):
                prev = e['prev'] if e['prev'] is not None else e['t']
                if e['aid'] and e['aid'] not in aid_used and e['buyout'] == L['unit'] and e['t'] >= L['t'] - LST_SLACK \
                        and prev <= L['finish'] + LST_SLACK:
                    if e['kind'] == 'osold' and e['aid'] not in seen and len(sold_list) < L['n']:
                        seen.add(e['aid'])
                        sold_list.append(e)
                    elif e['kind'] == 'ocancel':
                        cancels.append(e)
            for e in sold_list:
                aid_used.add(e['aid'])
            extra = len(sold_list) - L['sold']
            if extra > 0:
                for e in sold_list[len(sold_list) - extra:]:
                    L['times'].append((self._mid(e), 1))
                L['sold'] += extra
            rest = L['n'] - L['sold']
            cancel_aids, last = set(), None
            for e in cancels:
                if e['aid'] not in cancel_aids and rest > 0:
                    cancel_aids.add(e['aid'])
                    aid_used.add(e['aid'])
                    L['cancelled'] += 1
                    rest -= 1
                    if last is None or e['t'] > last:
                        last = e['t']
            if last is not None:
                L['finish'] = min(L['finish'], last)
            if rest > 0:
                if now < L['finish']:
                    L['open'] = True
                else:
                    L['expired'] = rest

    def _commodities(self, posts, by_aid, expiries, looked):
        used = set()
        for L in posts:
            if L['kind'] != 'c':
                continue
            evs = by_aid.get(L['aid'], []) if L['aid'] else []
            parts, buys, part_sum, buy_sum = [], [], 0, 0
            cancel = gone = None
            for e in evs:
                if e['kind'] == 'opart':
                    parts.append(e)
                    part_sum += e['qty']
                elif e['kind'] == 'osold' and (e['qty'] == 1 or e['buyout'] != L['unit']):
                    buys.append(e)
                    buy_sum += e['qty']
                elif e['kind'] == 'ocancel' and cancel is None:
                    cancel = e
                if e['kind'] in ('ogone', 'oexpire'):
                    gone = e
            returned = None
            if cancel:
                returned = min(L['n'], cancel['qty'])
                L['cancelled'] = returned
                L['finish'] = cancel['t']
            else:
                best, gap = None, None
                for mail in expiries.get(L['key'], []):
                    if id(mail) not in used and mail['qty'] <= L['n']:
                        d = abs(mail['t'] - L['finish'])
                        if d <= LST_EXPIRY_SLACK and (gap is None or d < gap):
                            best, gap = mail, d
                if best:
                    used.add(id(best))
                    returned = best['qty']
                    L['expired'] = returned
                elif gone:
                    returned = min(L['n'], gone['qty'])
                    L['expired'] = returned
            if returned is not None:
                L['sold'] = L['n'] - returned
            elif looked.get(L['char'], -math.inf) < L['finish']:
                L['open'] = True
                L['sold'] = min(L['n'], max(part_sum, buy_sum))
            else:
                L['sold'] = L['n']
            left = L['sold']
            for e in (parts if part_sum >= buy_sum else buys):
                q = min(e['qty'], left)
                if q > 0:
                    L['times'].append((self._mid(e), q))
                    left -= q

    # ---- the questions Picks asks (trade/Listings.lua)
    @staticmethod
    def sold_before(L, t):
        if t <= L['t']:
            return 0
        if t >= L['finish']:
            return L['sold']
        known = done = 0
        for m, q in L['times']:
            known += q
            if m <= t:
                done += q
        rest = L['sold'] - known
        if rest > 0:
            done += rest * (t - L['t']) / max(1, L['finish'] - L['t'])
        return done

    def listed(self, key, t):
        return sum(L['n'] - self.sold_before(L, t) for L in self.by_key.get(key, []) if L['t'] < t < L['finish'])

    def listed_minutes(self, key, a, b):
        spans = []
        for L in self.by_key.get(key, []):
            s, e = max(L['t'], a), min(L['finish'], b)
            if L['sold'] >= L['n'] and L['times']:
                e = min(e, L['times'][-1][0])
            if e > s:
                spans.append((s, e))
        spans.sort()
        total, cur = 0, None
        for s, e in spans:
            if cur and s <= cur[1]:
                cur[1] = max(cur[1], e)
            else:
                if cur:
                    total += cur[1] - cur[0]
                cur = [s, e]
        if cur:
            total += cur[1] - cur[0]
        return total

    def sold_in(self, key, a, b):
        return sum(self.sold_before(L, b) - self.sold_before(L, a) for L in self.by_key.get(key, []))

    def proven(self, key, at=None):
        """{proven, ranOut, at, sold72} at minute `at` (default: now): the most of your units of the key sold within
        (p.t, min(p.t + 8h, at)] over your posts p of the 72h before it"""
        now = self.now if at is None else at
        if at is None and key in self._proven:
            return self._proven[key]
        got = {'proven': 0, 'ranOut': False, 'at': None, 'sold72': 0}
        if key in self.by_key:
            got['sold72'] = self.sold_in(key, now - LST_WINDOW, now)
            for L in self.by_key[key]:
                if now - LST_WINDOW <= L['t'] < now:
                    a, b = L['t'], min(L['t'] + LST_PROVEN, now)
                    s = self.sold_in(key, a, b)
                    if s > got['proven'] + 1e-9:
                        got['proven'], got['at'] = s, a
                        got['ranOut'] = self.listed(key, b - 1) < 0.5 or self.listed_minutes(key, a, b) < (b - a) - LST_GAP
        if at is None:
            self._proven[key] = got
        return got


def minutes_of(epoch):
    return (epoch - EPOCH) / 60


def epoch_of(minutes):
    return EPOCH + minutes * 60

class MarketAt:
    """One item's deep records up to the epoch t, as the AddOn could know the market then (FRV-111 signals.At)"""

    def __init__(self, recs, t):
        times = [x['t'] for x in recs]
        self.t = t
        self.recs = recs[:bisect.bisect_right(times, t)]
        self.last = self.recs[-1] if self.recs else None

    def window(self, hours):
        since = self.t - hours * 3600
        return [x for x in self.recs if x['t'] > since]

    def history_hours(self):
        return (self.t - self.recs[0]['t']) / 3600 if self.recs else 0

    def price(self, rec=None):
        rec = rec or self.last
        return (rec.get('minOther') or rec.get('min')) if rec else None

    def circ12(self, hours):
        sold = cover = 0.0
        for x in self.window(hours):
            gap = x.get('gap')
            if gap and 0 < gap <= CLEAN_GAP_MIN:
                cover += gap
                if not x.get('unchanged'):
                    sold += (x.get('sold') or 0) + 0.5 * (x.get('amb') or 0)
        return (sold * 720 / cover) if cover >= MIN_COVER_H * 60 else None

    def c24(self):
        rate = self.circ12(12)
        if rate is None:
            rate = self.circ12(72)
        return rate * 2 if rate is not None else None

    def demand(self, hours=72):
        """trade/Picks.lua Demand: buyers per day from soldLow, relist bursts capped"""
        bought = cover = 0.0
        intervals = auctions = 0
        prev_qty = None
        since = self.t - hours * 3600
        for x in self.recs:
            if x['t'] > since:
                gap = x.get('gap')
                if gap and 0 < gap <= CLEAN_GAP_MIN:
                    cover += gap
                    if not x.get('unchanged'):
                        sold = x.get('sold') or 0
                        units = x.get('soldLow')
                        if units is None:
                            units = sold * 0.3
                        if prev_qty and sold > 0.3 * prev_qty and (x.get('new') or 0) >= 0.5 * sold:
                            units = min(units, 0.15 * prev_qty)
                        if units > 0:
                            bought += units
                            intervals += 1
                            auctions += x.get('soldN') or 0
            prev_qty = x.get('qty') or 0
        if cover < MIN_COVER_H * 60:
            return None, False
        return bought / cover * 1440, intervals >= 3 and auctions >= 5


# the Picks batch of 1.40 (trade/Picks.lua Batch): items, commodities
LST_RULE = {'i': dict(first=0.5, floor=10, grow=1.25, hold=0.75, lo=0.5, hi=1.0, hi_at=4.0, units=100),
            'c': dict(first=0.06, floor=0, grow=1.25, hold=0.75, lo=0.5, hi=2.0, hi_at=4.0, units=200)}
LST_VIEWS = ('cut', 'none', 'mid', 'curve')
LST_AGE_EDGES = [0, 0.25, 0.5, 1, 2, 4, 8]


def _listing_rows(m, book, settings, older=()):
    """Every listing with the market at its post, its cost, its 8h deposit and its proven record (FRV-115 b0). The
    AddOn keeps an item's deep records 72h (FM.LIMITS.detailHours): older copies of the saved variables (`older`,
    newest first) add the records they still had from before the main file's first one, as the analysis did"""
    r = m.r
    recs_of = {}

    def recs(key):
        if key not in recs_of:
            out = [x for x in m.records(key) if x['kind'] == 'r' and x['t']]
            first = out[0]['t'] if out else math.inf
            for om in older:
                extra = [x for x in om.records(key) if x['kind'] == 'r' and x['t'] and x['t'] < first - 30]
                if extra:
                    out = extra + out
                    first = out[0]['t']
            recs_of[key] = out
        return recs_of[key]

    # the craft log: the materials' basis per unit made, a material over 2.5 times its usual basis set to it (FRV-112)
    crafts = []
    for line in as_list(r.get('crafts')):
        f = str(line).split(',')
        if len(f) < 3:
            continue
        mats = []
        for part in (f[6].split('/') if len(f) > 6 and f[6] else []):
            b = part.split(':')
            if len(b) >= 3:
                mats.append((b[0], int(b[1] or 0), int(b[2]) if b[2] else None))
        crafts.append((int(f[0]), f[1], int(f[2] or 0), mats))
    per_mat = {}
    for _, _, _, mats in crafts:
        for key, units, copper in mats:
            if copper is not None and units:
                per_mat.setdefault(key, []).append(copper / units)
    med = {k: statistics.median(v) for k, v in per_mat.items()}
    craft_lines = {}
    for t, key, units, mats in crafts:
        if not units or any(c is None or not u for _, u, c in mats):
            continue
        total = 0.0
        for k, u, c in mats:
            per = c / u
            total += (med[k] if per > 2.5 * med[k] else per) * u
        craft_lines.setdefault(key, []).append((t, total / units, units))
    buys = []
    for line in as_list(r.get('buys')):
        f = str(line).split(',')
        if len(f) >= 4:
            buys.append((int(f[0]), f[1], int(f[2]), int(f[3])))
    vendor = {}
    for k, line in (r.get('vendorSeen') or {}).items():
        try:
            vendor[str(k)] = float(str(line).split(',')[0])
        except ValueError:
            pass
    recipes = {}
    for _, _, _, rs in load_reagent_dbs(m.sv_dir, None):
        for rname, rc in (rs or {}).items():
            if isinstance(rc, dict) and rc.get('itemId'):
                mats = [(str(g.get('id')), g.get('n') or 1) for g in as_list(rc.get('reagents')) if isinstance(g, dict) and g.get('id')]
                if mats:
                    recipes.setdefault(str(rc['itemId']), {'makes': rc.get('makes') or 1, 'mats': mats})

    def mat_price(key, t):
        v = vendor.get(key)
        ah = MarketAt(recs(key), t).price()
        return v if v is not None and (ah is None or v <= ah) else ah

    def cost_of(key, t):
        lines = craft_lines.get(key)
        if lines:
            near = [(c, u) for ct, c, u in lines if t - 48 * 3600 <= ct <= t + 900] or [(c, u) for _, c, u in lines]
            return sum(c * u for c, u in near) / sum(u for _, u in near), 'craft'
        mine = [b for b in buys if b[1] == key and b[0] <= t + 900]
        if mine:
            near = [b for b in mine if b[0] >= t - 72 * 3600] or mine
            return sum(b[3] for b in near) / sum(b[2] for b in near), 'bought'
        if key in vendor:
            return vendor[key], 'vendor'
        rc = recipes.get(key)
        if rc:
            total = 0.0
            for mk, n in rc['mats']:
                p = mat_price(mk, t)
                if p is None:
                    return None, 'none'
                total += p * n
            return total / rc['makes'], 'recipe'
        return None, 'none'

    # the 8h deposit of a unit: your sale mails' median, the measured one, else the median share of the price
    dep_mail = {}
    names = r.get('names') or {}
    key_of = {v: k for k, v in names.items()}
    for line in as_list(r.get('invoices')):
        f = str(line).split(',')
        if len(f) > 8 and f[2] == 'seller' and f[3] in key_of:
            qty, dep = b36(f[5]) or 1, b36(f[8]) or 0
            if dep:
                dep_mail.setdefault(key_of[f[3]], []).append(dep / qty)
    dep_mail = {k: statistics.median(v) for k, v in dep_mail.items()}
    dep_meas = {}
    for k, e in (r.get('deposits') or {}).items():
        d2 = e.get(2) if isinstance(e, dict) else (e[1] if isinstance(e, list) and len(e) > 1 else None)
        v = d2.get(1) if isinstance(d2, dict) else (d2[0] if isinstance(d2, list) and d2 else None)
        if isinstance(v, (int, float)) and v > 0:
            dep_meas[str(k)] = v

    rows = []
    for L in book.listings:
        t = epoch_of(L['t'])
        if L['kind'] == 'c' and t < LST_COMMODITY_FROM:
            continue
        at = MarketAt(recs(L['key']), t - 60)
        if not at.last or at.history_hours() < 10:
            continue
        buyers, trusted = at.demand()
        p = book.proven(L['key'], at=L['t'])
        row = dict(L)
        row.update({'name': m.name(L['key']), 'tE': t, 'buyers': buyers, 'trusted': trusted, 'c24': at.c24(),
                    'others': (at.last.get('qty') or 0) - (at.last.get('own') or 0),
                    'listed': book.listed(L['key'], L['t'] - 1), 'depth': p['proven'], 'depth_out': p['ranOut'],
                    'h_times': [((mm - L['t']) / 60, q) for mm, q in L['times']]})
        row['cost'], row['cost_src'] = cost_of(L['key'], t)
        rows.append(row)
    shares = {'i': [], 'c': []}
    for row in rows:
        if row['key'] in dep_mail and row['unit']:
            shares[row['kind']].append(dep_mail[row['key']] / row['unit'])
    kind_share = {k: (statistics.median(v) if v else 0.04) for k, v in shares.items()}
    for row in rows:
        if row['key'] in dep_mail:
            row['dep8'], row['dep_src'] = dep_mail[row['key']], 'mail'
        elif row['key'] in dep_meas:
            row['dep8'], row['dep_src'] = dep_meas[row['key']], 'measured'
        else:
            row['dep8'], row['dep_src'] = kind_share[row['kind']] * row['unit'], 'share'
        row['net'] = row['unit'] * (1 - AH_CUT)
        row['margin'] = row['net'] - row['cost'] if row['cost'] is not None else None
        known = sum(q for _, q in row['h_times'])
        row['tau'] = (max(h for h, _ in row['h_times']) if row['sold'] >= row['n'] and row['h_times']
                      and known >= 0.9 * row['sold'] else None)
    return rows


def _hours_of_buyers(tau, curve):
    tot, prev = 0.0, 0.0
    for edge, share in curve:
        if tau <= prev:
            break
        tot += (min(tau, edge) - prev) * share
        prev = edge
    return tot


def _age_curve(rs):
    """the share of the average buyer rate a listing gets, by its age (FRV-111 a2b)"""
    out = []
    for a, b in zip(LST_AGE_EDGES, LST_AGE_EDGES[1:]):
        num = den = 0.0
        for x in rs:
            times = sorted(h for h, q in x['h_times'] for _ in range(int(q)))
            sold_out = x['sold'] >= x['n']
            last = times[-1] if sold_out and times else 8
            if sold_out and times:
                times = times[:-1]
            hi = min(b, last)
            if hi > a:
                den += x['buyers'] / 24 * (hi - a)
            num += sum(1 for h in times if a < h <= b)
        out.append((b, num / den if den else 0.0))
    return out


def _episodes(rows):
    """your posts of one item within 8h of the first of them, 8h listings (FRV-115 b1): N listed, S sold, the margin and
    the deposit by units, and the demand D under four views (cut, none, curve, mid)"""
    def timed(x):
        return x['sold'] == 0 or sum(q for _, q in x['h_times']) >= 0.9 * x['sold']
    closed = [x for x in rows if not x['open'] and not x['cancelled'] and x['hours'] == 8]
    curve = {'i': _age_curve([x for x in closed if x['kind'] == 'i' and x['buyers']]),
             'c': _age_curve([x for x in closed if x['kind'] == 'c' and x['buyers'] and timed(x)])}
    h8 = {k: _hours_of_buyers(8, curve[k]) for k in curve}
    eight = sorted([x for x in rows if x['hours'] == 8], key=lambda x: (x['key'], x['t']))
    eps = []
    i = 0
    while i < len(eight):
        first = eight[i]
        group = [first]
        j = i + 1
        while j < len(eight) and eight[j]['key'] == first['key'] and eight[j]['t'] <= first['t'] + 8 * 60:
            group.append(eight[j])
            j += 1
        i = j
        if any(x['open'] or x['cancelled'] for x in group):
            continue
        N, S = sum(x['n'] for x in group), sum(x['sold'] for x in group)
        e = {'key': first['key'], 'name': first['name'], 'kind': first['kind'], 't': first['tE'], 'posts': group,
             'N': N, 'S': S, 'first': first, 'listed0': first['listed'], 'exact': any(x['sold'] < x['n'] for x in group)}
        e['unit'] = sum(x['unit'] * x['n'] for x in group) / N
        e['dep'] = sum(x['dep8'] * x['n'] for x in group) / N
        costs = [x for x in group if x['margin'] is not None]
        e['margin'] = sum(x['margin'] * x['n'] for x in costs) / sum(x['n'] for x in costs) if costs else None
        if e['margin'] is not None and abs(e['margin']) > 3 * e['unit']:
            e['margin'] = None  # a recipe that does not fit the item
        if e['exact']:
            e['D'] = {v: S for v in LST_VIEWS}
        else:
            k = first['kind']
            cur = None
            if all(x['tau'] is not None for x in group):
                expo = sum(_hours_of_buyers(max(x['tau'], 5 / 60), curve[k]) for x in group)
                cur = max(N, N * h8[k] / expo) if expo > 0 else N
            e['D'] = {'cut': N, 'none': N, 'curve': cur if cur is not None else N,
                      'mid': math.sqrt(N * cur) if cur is not None else N}
        eps.append(e)
    return eps, curve, h8


def _cost(e):
    return e['unit'] * (1 - AH_CUT) - e['margin']


def _profit_rule(settings):
    """the Picks row's Profit (trade/Picks.lua FM.PicksProfit, FRV-126): the % of a unit's cost and / or the amount,
    with both checked 'either' (the lower minimum, the default) or 'both' (the higher); 10% alone by default"""
    settings = settings or {}
    amount_on = settings.get('tableProfitManual') is True
    pct_on = settings.get('tableProfitPctOn') is not False or not amount_on
    pct = min(999, max(0, int(settings.get('tableProfitPct', 10) or 0))) if pct_on else None
    amount = max(0, int(settings.get('tableProfitAmount', 10) or 0)) if amount_on else None
    logic = ('both' if settings.get('tableProfitLogic') == 'both' else 'either') if pct_on and amount_on else None
    return {'pct': pct, 'amount': amount, 'logic': logic}


def _min_unit(profit, cost):
    """the minimum profit of a unit that costs `cost` (trade/Picks.lua FM.PicksMinUnit)"""
    by_pct = profit['pct'] / 100 * max(0, cost) if profit['pct'] is not None else None
    if by_pct is not None and profit['amount'] is not None:
        return max(by_pct, profit['amount']) if profit['logic'] == 'both' else min(by_pct, profit['amount'])
    return by_pct if by_pct is not None else (profit['amount'] or 0)


def _min_profit(e, profit):
    # the Profit of the Picks row since 1.42 (FRV-126); 10c and 3% of the cost were built in before
    return e['margin'] >= _min_unit(profit, _cost(e))


def _rule(params, room, first_share, profit):
    """the batch limit at the episode's first post (trade/Picks.lua Batch, before what you list), 0 = no pick"""
    def rule(e):
        x = e['first']
        k = LST_RULE[x['kind']] if params is None else params[x['kind']]
        if not _min_profit(e, profit):
            return 0.0
        rho = e['margin'] / e['dep'] if e['dep'] > 0 else 99.0
        b8 = x['buyers'] * 8 / 24 if x['buyers'] and x['trusted'] else None
        first = False
        if x['depth'] > 0:
            base = (k['grow'] if x['depth_out'] else k['hold']) * x['depth']
        elif b8:
            base = max(k['first'] * b8, k['floor'])
            first = True
        else:
            return 0.0
        eco = k['lo'] if rho < 1 else (k['hi'] if rho >= k['hi_at'] else 1.0)
        lim = base * eco
        if x['c24']:
            lim = min(lim, int(room * x['c24'] + 0.5))
            if first and x['kind'] == 'c':
                lim = min(lim, first_share * x['c24'])
        if k.get('units'):
            lim = min(lim, k['units'])
        return lim
    return rule


def _as_listed(e):
    return e['N'] + e['listed0']


def _gold(es, rule, view):
    t = {'L': 0.0, 'S': 0.0, 'U': 0.0, 'profit': 0.0, 'dep': 0.0}
    for e in es:
        L = max(0.0, math.floor(rule(e) - e['listed0'] + 1e-9))
        if view == 'cut':
            L = min(e['N'], L)
        S = min(e['D'][view], L)
        t['L'] += L
        t['S'] += S
        t['U'] += L - S
        t['profit'] += S * e['margin']
        t['dep'] += (L - S) * e['dep']
    t['net'] = t['profit'] - t['dep']
    return t


def _plans(m, book, last):
    """the plan log (R.plans) against what was listed and sold of each pick's item after its plan"""
    plans = {}
    for line in as_list(m.r.get('plans')):
        f = str(line).split(',')
        # a line marked "e" is a pick whose amount you set in the table (1.47, FRV-154): your number, not the
        # formula's, so it is left out; the plan's own line of that pick is in the log too. "r" (1.57, FRV-188): a pick
        # planned around your amounts (a plan made again after an edit, or one keeping your set picks), also left out
        if len(f) > 9 and ('e' in f[9] or 'r' in f[9]):
            continue
        if len(f) >= 9:
            plans.setdefault(b36(f[0]), []).append({'char': f[1], 'key': f[2], 'kind': f[3], 'batch': int(f[4] or 0),
                                                    'invest': int(f[5] or 0), 'expected': int(f[6] or 0),
                                                    'conf': int(f[7] or 0), 'rank': int(f[8] or 0),
                                                    'extra': len(f) > 9 and f[9] == 'x'})
    if not plans:
        print('\nThe plan log is empty: Picks logs every plan since 1.40 (FRV-103).')
        return
    rows, tot = [], {}
    for t in sorted(plans):
        for p in sorted(plans[t], key=lambda p: p['rank']):
            # your posts of its item within 12h after the plan, and what each sold within its first 8h
            posts = [L for L in book.by_key.get(p['key'], []) if t <= L['t'] < t + 12 * 60]
            listed = sum(L['n'] for L in posts)
            sold = sum(book.sold_before(L, L['t'] + 8 * 60) for L in posts)
            value = sum(book.sold_before(L, L['t'] + 8 * 60) * L['unit'] for L in posts)
            p.update({'t': t, 'listed': listed, 'sold': sold, 'value': value})
            g = tot.setdefault((p['kind'], 'also good' if p['extra'] else 'plan'), [0, 0, 0, 0.0, 0.0])
            g[0] += 1
            g[1] += 1 if listed else 0
            g[2] += p['batch']
            g[3] += listed
            g[4] += sold
            rows.append(p)
    print('\nThe plan log (%d plans, %d picks): what you listed of each pick\'s item within 12h of its plan, and what '
          'those listings sold within 8h' % (len(plans), len(rows)))
    table([[k, part, n, done, b, '%.0f' % li, '%.0f' % so, '%.0f%%' % (100 * so / li) if li else '-']
           for (k, part), (n, done, b, li, so) in sorted(tot.items())],
          ['kind', 'part', 'picks', 'listed', 'batches', 'units listed', 'sold in 8h', 'sold of listed'])
    shown = [p for p in rows if p['t'] in sorted(plans)[-last:]]
    print('  the last %d plans:' % min(last, len(plans)))
    table([[when(epoch_of(p['t'])), p['rank'], ('(also) ' if p['extra'] else '') + m.name(p['key'])[:26], p['kind'], p['batch'],
            money(p['invest']), money(p['expected']), '%d%%' % p['conf'], p['listed'], '%.0f' % p['sold'], money(p['value'])]
           for p in shown],
          ['planned', '#', 'item', 'kind', 'batch', 'invest', 'expected', 'conf', 'listed', 'sold 8h', 'sold value'])


def cmd_listings(m, args):
    now = minutes_of(m.saved_at)
    # commodity posts before LST_COMMODITY_FROM have no auction ID: their outcome cannot be read, so they stay out of
    # the book itself (as in the reference), not only out of the tables; ListingsBook's rules stay the AddOn's
    cutoff = minutes_of(LST_COMMODITY_FROM)
    realm = dict(m.r)
    realm['posts'] = [line for line in as_list(m.r.get('posts'))
                      if not (len(str(line).split(',')) > 6 and str(line).split(',')[6] == 'c'
                              and (b36(str(line).split(',')[0]) or 0) < cutoff)]
    # the events log keeps its newest lines only (FM.LIMITS.eventsMax): a post before its first line of your auctions
    # (stamped when it was logged) can have lost its cancels, parts and sales, so the book starts there
    start = -math.inf
    for line in as_list(m.r.get('events')):
        f = str(line).split(',')
        if len(f) > 2 and f[2] in ('osold', 'opart', 'ocancel', 'ogone', 'oexpire') and b36(f[0]) is not None:
            start = b36(f[0])
            break
    book = ListingsBook(realm, now, since=start)
    older = []
    for path in sorted(args.older or [], key=os.path.getmtime, reverse=True):
        older.append(Market(path, m.realm_key, m.char))
    settings = m.settings or {}
    room = (settings.get('tableCircPct') or 25) / 100
    first_share = (settings.get('tableFirstPct') or 2) / 100
    profit = _profit_rule(settings)
    # ---- every post's outcome
    by = {}
    for L in book.listings:
        if L['kind'] == 'c' and epoch_of(L['t']) < LST_COMMODITY_FROM:
            continue
        by.setdefault((L['kind'], L['key']), []).append(L)
    print('Your listings (posts since %s, where the log of your auctions starts; commodity posts from %s on):' % (
        when(epoch_of(min(L['t'] for L in book.listings))) if book.listings else '-', when(LST_COMMODITY_FROM)))
    for kind, label in (('i', 'items'), ('c', 'commodities')):
        ls = [L for (k, _), lst in by.items() if k == kind for L in lst]
        print('  %s: %d posts, %d units, sold %d, expired %d, cancelled %d, running %d' % (
            label, len(ls), sum(L['n'] for L in ls), round(sum(L['sold'] for L in ls)), sum(L['expired'] for L in ls),
            sum(L['cancelled'] for L in ls), round(sum(L['n'] - L['sold'] for L in ls if L['open']))))
    out = []
    for (kind, key), ls in sorted(by.items(), key=lambda kv: -sum(L['n'] for L in kv[1])):
        closed = [L for L in ls if not L['open']]
        p = book.proven(key)
        out.append([m.name(key)[:28], kind, len(ls), sum(L['n'] for L in ls), round(sum(L['sold'] for L in ls)),
                    sum(L['expired'] for L in ls), sum(L['cancelled'] for L in ls),
                    round(sum(L['n'] - L['sold'] for L in ls if L['open'])),
                    '%.0f%%' % (100 * sum(L['sold'] for L in closed) / sum(L['n'] for L in closed)) if closed else '-',
                    ('%.0f %s' % (p['proven'], 'ran out' if p['ranOut'] else 'left')) if p['proven'] else '-'])
    table(out[:args.rows], ['item', 'k', 'posts', 'units', 'sold', 'exp', 'can', 'running', 'sold of closed', 'proven now'])

    # ---- the backtest in gold
    rows = _listing_rows(m, book, settings, older)
    eps, curve, h8 = _episodes(rows)
    if eps:
        print('\nThe backtest covers your 8h posts from %s to %s: an item\'s deep records are kept 72h, so a post needs '
              '10h of them before it%s' % (when(min(e['t'] for e in eps)), when(max(e['t'] for e in eps)),
                                         '; %d older copies add theirs' % len(older) if older else
                                         ' (--older <copy of ForeverMarket.lua> adds the records of older copies)'))
    priced = [e for e in eps if e['margin'] is not None]
    print('\nEpisodes (your 8h posts of one item within 8h of the first, with 10h+ of records before): %d, items %d, '
          'commodities %d; with a cost %d (%s); units left %d, sold out %d' % (
              len(eps), sum(1 for e in eps if e['kind'] == 'i'), sum(1 for e in eps if e['kind'] == 'c'), len(priced),
              ', '.join('%s %d' % (s, sum(1 for x in rows if x['cost_src'] == s)) for s in ('craft', 'bought', 'vendor', 'recipe', 'none')),
              sum(1 for e in eps if e['exact']), sum(1 for e in eps if not e['exact'])))
    for k in ('i', 'c'):
        print('  age curve %s: %s -> %.2f hours of buyers in 8h' % (k, ' '.join('%sh:%.2f' % (a, s) for a, s in curve[k]), h8[k]))
    if not priced:
        print('  no episode with a known cost yet: the gold table needs your 8h listings with records before them')
    else:
        formula = _rule(None, room, first_share, profit)
        rules = (('as listed', _as_listed), ('the formula', formula))
        print('\nThe gold table (the 1.40 batch against what you listed; a rule lists its limit less what you list, of the '
              'demand it sells what it can, every unsold unit pays its 8h deposit):')
        for v, title in (('cut', 'cut only (a rule may only shorten what you listed)'),
                         ('none', 'nothing more (a sold-out episode had no further demand)'),
                         ('mid', 'middle (between nothing more and the speed of the sell-out)'),
                         ('curve', 'speed (demand from how fast it sold out)')):
            print('  ' + title)
            tab = []
            for kind, label in (('i', 'Items'), ('c', 'Commodities'), (None, 'Together')):
                es = [e for e in priced if kind is None or e['kind'] == kind]
                for name, rule in rules:
                    t = _gold(es, rule, v)
                    tab.append([label, name, '%.0f' % t['L'], '%.0f' % t['S'], '%.0f' % t['U'], money(t['profit']),
                                money(t['dep']), money(t['net'])])
            table(tab, ['', 'rule', 'listed', 'sold', 'unsold', 'profit of sold', 'deposits lost', 'net'])
        rnd = random.Random(21)
        keys = sorted({e['key'] for e in priced})
        byk = {k: [e for e in priced if e['key'] == k] for k in keys}
        samples = [[e for k in (rnd.choice(keys) for _ in keys) for e in byk[k]] for _ in range(args.resamples)]
        n = len(samples)
        print('\nThe formula against what you listed, net gold (90%% of %d resamples of the %d items; share above 0):' % (n, len(keys)))
        for v in LST_VIEWS:
            diffs = sorted(_gold(s, formula, v)['net'] - _gold(s, _as_listed, v)['net'] for s in samples)
            print('  %-5s %12s  (%s .. %s; above 0 in %.0f%%)' % (v, money(_gold(priced, formula, v)['net'] - _gold(priced, _as_listed, v)['net']),
                                                               money(diffs[int(0.05 * n)]), money(diffs[int(0.95 * n)]), 100 * sum(1 for x in diffs if x > 0) / n))
        print('\nThe share of the listed units that sells under the formula (Expected counts 75% of an item\'s, 40% of a commodity\'s):')
        for kind in ('i', 'c'):
            for v in LST_VIEWS:
                t = _gold([e for e in priced if e['kind'] == kind], formula, v)
                qs = sorted(tt['S'] / tt['L'] for tt in (_gold([e for e in s if e['kind'] == kind], formula, v) for s in samples) if tt['L'])
                if t['L'] and qs:
                    print('  %s %-5s %.0f%%  (%.0f%% .. %.0f%%)' % (kind, v, 100 * t['S'] / t['L'], 100 * qs[int(0.05 * len(qs))], 100 * qs[int(0.95 * len(qs))]))
        # ---- the batch constants: the value that earns the most per resample
        print('\nThe batch constants: the value that earns the most per resample (share of resamples), views none and mid:')
        grids = [('i', 'first', (0.25, 0.5, 1.0, 2.0)), ('i', 'floor', (0, 5, 10, 15, 20, 30)), ('i', 'grow', (1.0, 1.25, 1.5, 2.0)),
                 ('i', 'hold', (0.5, 0.75, 1.0, 1.25)), ('i', 'lo', (0.25, 0.5, 0.75, 1.0)),
                 ('c', 'first', (0.03, 0.06, 0.09, 0.12)), ('c', 'grow', (1.0, 1.25, 1.5, 2.0)), ('c', 'hold', (0.5, 0.75, 1.0, 1.25)),
                 ('c', 'lo', (0.25, 0.5, 0.75, 1.0)), ('c', 'hi', (1.0, 1.5, 2.0, 3.0)), ('c', 'units', (100, 200, 400, None))]
        for kind, name, vals in grids:
            es_all = [e for e in priced if e['kind'] == kind]
            if not es_all:
                continue
            rules_v = []
            for val in vals:
                params = {k: dict(LST_RULE[k]) for k in LST_RULE}
                params[kind][name] = val
                rules_v.append(_rule(params, room, first_share, profit))
            parts = []
            for v in ('none', 'mid'):
                wins = {val: 0 for val in vals}
                for s in samples:
                    ss = [e for e in s if e['kind'] == kind]
                    nets = [_gold(ss, rl, v)['net'] for rl in rules_v]
                    wins[vals[max(range(len(vals)), key=lambda i: nets[i])]] += 1
                parts.append('%s: %s' % (v, ' '.join('%s:%.0f%%' % (val, 100 * wins[val] / n) for val in vals)))
            print('  %s %-5s (now %s)  %s' % (kind, name, LST_RULE[kind][name], ' | '.join(parts)))
        # ---- measured shares, resampled by item
        print('\nMeasured shares (5th .. 95th percentile over resamples of the items):')
        closed = [x for x in rows if not x['open'] and not x['cancelled'] and x['hours'] == 8]

        def boot(rs, label):
            ks = sorted({x['key'] for x in rs})
            if not ks:
                return
            byr = {k: [x for x in rs if x['key'] == k] for k in ks}
            vals = []
            for _ in range(n):
                s = [x for k in (rnd.choice(ks) for _ in ks) for x in byr[k]]
                den = sum(x['n'] for x in s)
                if den:
                    vals.append(sum(x['sold'] for x in s) / den)
            vals.sort()
            full = sum(x['sold'] for x in rs) / max(1, sum(x['n'] for x in rs))
            print('  %-56s %4.0f%%  (%.0f%% .. %.0f%%)  %d listings, %d items' % (
                label, 100 * full, 100 * vals[int(0.05 * len(vals))], 100 * vals[int(0.95 * len(vals)) - 1], len(rs), len(ks)))
        it = [x for x in closed if x['kind'] == 'i']
        co = [x for x in closed if x['kind'] == 'c']
        boot(it, 'items, every 8h listing: units sold')
        boot(co, 'commodities, every 8h listing: units sold')
        boot([x for x in it if x['depth'] > 0 and x['depth_out'] and (x['n'] + x['listed']) <= x['depth'] * 1.25],
             'items, up to 1.25 x the proven (ran out): units sold')
        boot([x for x in it if x['depth'] > 0 and not x['depth_out'] and (x['n'] + x['listed']) <= x['depth'] * 0.75],
             'items, up to 0.75 x the proven (units left): units sold')
        boot([x for x in it if x['buyers'] and x['others'] / x['buyers'] > 4], 'items, over 4 days of stock of others: units sold')
        boot([x for x in it if x['buyers'] and x['others'] / x['buyers'] <= 4], 'items, up to 4 days of stock of others: units sold')
        print('  (the wait table and the materials threshold are measured on the price dips, not on your listings)')
    _plans(m, book, args.plans)


# --------------------------------------------------------------------------- main


def main(argv=None):
    ap = argparse.ArgumentParser(description='ForeverMarket analyzer')
    ap.add_argument('--sv', help='path to WTF/.../SavedVariables/ForeverMarket.lua')
    ap.add_argument('--addon', help='path to Interface/AddOns/ForeverMarket')
    ap.add_argument('--realm', help='realm-faction filter')
    ap.add_argument('--char', help="the character whose own settings count (1.68: the plan's settings are saved per "
                                   'character); default: the one seen last')
    sub = ap.add_subparsers(dest='cmd', required=True)
    sub.add_parser('summary')
    p = sub.add_parser('item')
    p.add_argument('query')
    p.add_argument('--rows', type=int, default=24)
    p.add_argument('--history', action='store_true', help='include Auctionator daily history')
    p = sub.add_parser('price')
    p.add_argument('query')
    p.add_argument('--hours', type=float, default=8)
    p.add_argument('--conf', type=float, default=0.9)
    p.add_argument('--qty', type=int, default=1)
    p.add_argument('--cost', help='your cost per unit, e.g. 2s40c')
    p.add_argument('--rate', type=float, help='assume this many sold per day (when the data has no rate yet)')
    p.add_argument('--mode', choices=['all', 'fraction'], default='all',
                   help='all: P(every unit sold) >= conf; fraction: expected share sold >= conf')
    p = sub.add_parser('movers')
    p.add_argument('--top', type=int, default=15)
    p = sub.add_parser('sales')
    p.add_argument('--rows', type=int, default=30)
    p.add_argument('--days', type=int, default=14)
    p = sub.add_parser('craft')
    p.add_argument('--prof', help='e.g. Leatherworking')
    p.add_argument('--all', action='store_true', help='include recipes you have not learned')
    p.add_argument('--top', type=int, default=25)
    p = sub.add_parser('flips')
    p.add_argument('--budget', help='money to spend, e.g. 5g (default: your last known gold)')
    p.add_argument('--below', type=float, default=0.7, help='buy listings up to this share of the usual price')
    p.add_argument('--min-price', dest='min_price', type=int, default=20, help='usual price at least (copper)')
    p.add_argument('--min-profit', dest='min_profit', type=int, default=500, help='expected profit at least (copper)')
    p.add_argument('--max-age', dest='max_age', type=float, default=6, help='market data at most this old (hours)')
    p.add_argument('--top', type=int, default=20)
    p = sub.add_parser('room')
    p.add_argument('items', nargs='*', help='items to show (default: every item you listed in the window)')
    p.add_argument('--days', type=int, default=7, help='window for your sales and listings')
    p.add_argument('--share', type=float, help='share of C/24h in %% (default: your setting, else 25)')
    p = sub.add_parser('listings', help='your listings, the Picks batch backtested in gold, its constants, the plan log')
    p.add_argument('--rows', type=int, default=40, help='items in the outcome table')
    p.add_argument('--resamples', type=int, default=1000, help='resamples of the items for the ranges')
    p.add_argument('--plans', type=int, default=5, help='the last N plans of the plan log, pick by pick')
    p.add_argument('--older', action='append', metavar='PATH',
                   help='an older copy of ForeverMarket.lua whose deep records reach further back (repeatable)')
    args = ap.parse_args(argv)

    addon, sv = find_paths(args)
    args.addon, args.sv = addon, sv
    market = Market(sv, args.realm, args.char)
    {'summary': cmd_summary, 'item': cmd_item, 'price': cmd_price, 'movers': cmd_movers, 'sales': cmd_sales,
     'craft': cmd_craft, 'flips': cmd_flips, 'room': cmd_room, 'listings': cmd_listings}[args.cmd](market, args)


if __name__ == '__main__':
    main()
