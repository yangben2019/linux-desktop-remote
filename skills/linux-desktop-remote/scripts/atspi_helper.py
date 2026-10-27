#!/usr/bin/python3
# -*- coding: utf-8 -*-
"""AT-SPI semantic UI lookup/action helper used by remote.sh's ui-* commands.

Depends only on the system Python and python3-pyatspi (no screenshots, no OCR).
"""
from __future__ import print_function

import argparse
import sys

import gi

gi.require_version('Atspi', '2.0')
from gi.repository import Atspi

PREFERRED_ACTIONS = ('click', 'activate', 'press', 'open', 'menu')
FRAME_ROLES = ('frame', 'window', 'dialog')
TREE_ROLES = (
    'application', 'frame', 'window', 'dialog', 'menu bar', 'menu',
    'menu item', 'icon', 'push button', 'toggle button', 'table',
    'table cell', 'table row', 'list', 'list item', 'check box',
    'radio button', 'combo box', 'page tab', 'entry', 'text', 'label',
    'slider', 'spin button',
)


def desktop():
    return Atspi.get_desktop(0)


def safe(fn, default=None):
    try:
        return fn()
    except Exception:
        return default


def role_of(node):
    return safe(node.get_role_name, '') or ''


def name_of(node):
    return safe(node.get_name, '') or ''


def extents(node):
    try:
        e = node.get_extents(Atspi.CoordType.SCREEN)
        return (e.x, e.y, e.width, e.height)
    except Exception:
        return (-1, -1, -1, -1)


def is_visible(ext):
    x, y, w, h = ext
    return w > 1 and h > 1 and x > -1000 and y > -1000


def action_list(node):
    out = []
    try:
        for i in range(node.get_n_actions()):
            out.append(node.get_action_name(i))
    except Exception:
        pass
    return out


def state_set(node):
    out = set()
    try:
        ss = node.get_state_set()
        for key, st in (('active', Atspi.StateType.ACTIVE),
                        ('focused', Atspi.StateType.FOCUSED),
                        ('showing', Atspi.StateType.SHOWING),
                        ('enabled', Atspi.StateType.ENABLED)):
            if ss.contains(st):
                out.add(key)
    except Exception:
        pass
    return out


def walk_all(max_depth=60):
    """Depth-first generator over all accessible nodes with context."""
    stack = [(desktop(), 0, '', '', False)]
    while stack:
        node, depth, app, frame, frame_active = stack.pop()
        role = role_of(node)
        name = name_of(node)
        if role == 'application':
            app, frame, frame_active = name, '', False
        elif role in FRAME_ROLES:
            frame = name
            st = state_set(node)
            frame_active = ('active' in st) or ('focused' in st)
        yield {
            'obj': node, 'depth': depth, 'app': app, 'frame': frame,
            'frame_active': frame_active, 'role': role, 'name': name,
            'ext': extents(node), 'actions': action_list(node),
            'states': state_set(node),
        }
        if depth >= max_depth:
            continue
        count = safe(node.get_child_count, 0) or 0
        for i in range(count - 1, -1, -1):
            child = safe(lambda i=i: node.get_child_at_index(i))
            if child is not None:
                stack.append((child, depth + 1, app, frame, frame_active))


def name_match(name, query, contains=False):
    n = name.strip().lower()
    q = query.strip().lower()
    if not q:
        return False
    if contains:
        return q in n
    if n == q:
        return True
    # Tolerate menu mnemonic suffixes: "New" also matches "New(N)".
    return n.startswith(q) and n[len(q):].startswith('(')


def matches(info, args, want_action=None):
    if not name_match(info['name'], args.name, args.contains):
        return False
    if args.app and args.app.lower() not in info['app'].lower():
        return False
    if args.frame and args.frame.lower() not in info['frame'].lower():
        return False
    if args.role and info['role'].lower() != args.role.lower():
        return False
    if want_action:
        if want_action.lower() not in [a.lower() for a in info['actions']]:
            return False
    return True


def pick_action(actions, want=None):
    if want:
        for i, a in enumerate(actions):
            if a.lower() == want.lower():
                return i, a
        return None
    for preferred in PREFERRED_ACTIONS:
        for i, a in enumerate(actions):
            if a.lower() == preferred:
                return i, a
    if actions:
        return 0, actions[0]
    return None


def rank(info):
    score = 0
    if info['actions']:
        score += 1000
    if info['frame_active']:
        score += 200
    if is_visible(info['ext']):
        score += 100
    if 'enabled' in info['states']:
        score += 10
    return score - info['depth']


def fmt(info, index=None, picked=None):
    x, y, w, h = info['ext']
    prefix = '[{}] '.format(index) if index is not None else ''
    chosen = ' action={}'.format(picked[1]) if picked else ''
    return '{}role={} name={!r} app={!r} frame={!r} xywh={},{},{},{} actions={} states={}{}'.format(
        prefix, info['role'], info['name'], info['app'], info['frame'],
        x, y, w, h, ','.join(info['actions']) or '-',
        ','.join(sorted(info['states'])) or '-', chosen)


def cmd_apps(args):
    count = 0
    for info in walk_all(max_depth=1):
        if info['role'] != 'application':
            continue
        count += 1
        print('app={!r} children={}'.format(info['name'], safe(info['obj'].get_child_count, 0)))
    if count == 0:
        print('No accessible applications found (make sure apps were started after accessibility was enabled)', file=sys.stderr)
        return 2
    return 0


def cmd_frames(args):
    count = 0
    for info in walk_all(max_depth=2):
        if info['role'] not in FRAME_ROLES:
            continue
        if info['name'] == '' and not is_visible(info['ext']):
            continue
        count += 1
        print(fmt(info))
    if count == 0:
        print('No accessible windows found', file=sys.stderr)
        return 2
    return 0


def cmd_tree(args):
    printed = 0
    for info in walk_all(max_depth=args.depth):
        if args.query:
            q = args.query.lower()
            if q not in info['app'].lower() and q not in info['frame'].lower():
                continue
        if not args.all and not info['name'] and info['role'] not in TREE_ROLES:
            continue
        if not args.all and info['role'] not in TREE_ROLES and not info['name']:
            continue
        print('{}{}'.format('  ' * info['depth'], fmt(info)))
        printed += 1
        if printed >= args.limit:
            print('... reached --limit {}; raise the limit or narrow the scope'.format(args.limit))
            break
    return 0 if printed else 2


def cmd_find(args):
    infos = [i for i in walk_all() if matches(i, args)]
    infos.sort(key=lambda i: (rank(i), -i['depth']), reverse=True)
    for idx, info in enumerate(infos):
        print(fmt(info, index=idx))
    if not infos:
        print('Not found: {!r}'.format(args.name), file=sys.stderr)
        return 2
    return 0


def cmd_focus(args):
    infos = [i for i in walk_all() if matches(i, args)]
    infos.sort(key=lambda i: (rank(i), -i['depth']), reverse=True)
    for info in infos:
        comp = safe(info['obj'].get_component_iface)
        if comp and safe(lambda comp=comp: comp.grab_focus(), False):
            print('FOCUSED ' + fmt(info))
            return 0
    if infos:
        print('Target widget does not support focus: {!r}'.format(args.name), file=sys.stderr)
        return 3
    print('Not found: {!r}'.format(args.name), file=sys.stderr)
    return 2


def cmd_click(args):
    infos = [i for i in walk_all() if matches(i, args, args.action)]
    infos.sort(key=lambda i: (rank(i), -i['depth']), reverse=True)
    candidates = []
    no_action = []
    for info in infos:
        picked = pick_action(info['actions'], args.action)
        if picked:
            candidates.append((info, picked))
        else:
            no_action.append(info)
    if not candidates:
        if no_action and not args.action:
            info = no_action[0]
            if is_visible(info['ext']):
                x = info['ext'][0] + info['ext'][2] // 2
                y = info['ext'][1] + info['ext'][3] // 2
            else:
                x = y = -1
            print('NOACTION role={} name={!r} app={!r} frame={!r} x={} y={}'.format(
                info['role'], info['name'], info['app'], info['frame'], x, y))
            return 3
        print('No actionable widget found: {!r}'.format(args.name), file=sys.stderr)
        return 2
    if args.index < 0 or args.index >= len(candidates):
        print('Index out of range: {} actionable match(es)'.format(len(candidates)), file=sys.stderr)
        return 2
    info, picked = candidates[args.index]
    try:
        ok = info['obj'].do_action(picked[0])
    except Exception as exc:
        print('Action failed: {}'.format(exc), file=sys.stderr)
        return 3
    if not ok:
        print('Action returned failure: {}'.format(picked[1]), file=sys.stderr)
        return 3
    print('CLICKED ' + fmt(info, index=args.index, picked=picked))
    return 0


def add_filters(p, with_click=False):
    p.add_argument('name', help='widget name (exact match by default; mnemonic suffixes like "(N)" are allowed)')
    p.add_argument('--contains', action='store_true', help='match the name as a substring')
    p.add_argument('--app', help='restrict to an application name (substring)')
    p.add_argument('--frame', help='restrict to a window/frame title (substring)')
    p.add_argument('--role', help='restrict to a widget role, e.g. icon/menu item/push button')
    if with_click:
        p.add_argument('--action', help='action name; defaults to click/activate/press/open priority')
        p.add_argument('--index', type=int, default=0, help='pick the Nth match (default: 0)')


def build_parser():
    parser = argparse.ArgumentParser(description='AT-SPI semantic UI lookup/action')
    sub = parser.add_subparsers(dest='cmd')

    sub.add_parser('apps', help='list accessible applications')

    sub.add_parser('frames', help='list accessible windows')

    p = sub.add_parser('tree', help='print the widget tree')
    p.add_argument('query', nargs='?', default='', help='filter by application/window name')
    p.add_argument('--depth', type=int, default=8)
    p.add_argument('--limit', type=int, default=400)
    p.add_argument('--all', action='store_true', help='show all roles')

    p = sub.add_parser('find', help='find widgets by name')
    add_filters(p)

    p = sub.add_parser('focus', help='focus a widget/window by name (use before typing)')
    add_filters(p)

    p = sub.add_parser('click', help='invoke a widget action by name')
    add_filters(p, with_click=True)
    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()
    handlers = {
        'apps': cmd_apps, 'frames': cmd_frames, 'tree': cmd_tree,
        'find': cmd_find, 'focus': cmd_focus, 'click': cmd_click,
    }
    if args.cmd not in handlers:
        parser.print_help()
        return 1
    return handlers[args.cmd](args)


if __name__ == '__main__':
    sys.exit(main())
