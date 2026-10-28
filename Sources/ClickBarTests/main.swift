import Foundation
import ClickBarCore

var failures = 0
var count = 0
@MainActor func check(_ result: @autoclosure () -> Bool, _ name: String) {
    count += 1
    if !result() { failures += 1; print("FAIL: \(name)") }
}
let own = "local.chan.ClickBar"
let running: Set<String> = [own, "visible", "quick", "deep", "new-app", "helper"]
let groups: [String: IconGroup] = [own: .double, "visible": .always, "quick": .single, "deep": .double]
check(VisibilityPolicy.hidden(running: running, groups: groups, state: .collapsed, ownID: own) == ["quick", "deep"], "collapsed hides both groups, never self or new apps")
check(VisibilityPolicy.hidden(running: running, groups: groups, state: .single, ownID: own) == ["deep"], "single leaves deep group hidden")
check(VisibilityPolicy.hidden(running: running, groups: groups, state: .all, ownID: own).isEmpty, "double reveals both groups")
check(VisibilityPolicy.hidden(running: ["unconfigured"], groups: groups, state: .collapsed, ownID: own).isEmpty, "unconfigured apps stay visible")
check(VisibilityPolicy.allowing(running: running, hidden: ["quick", "deep"], ownID: own).contains("helper"), "background bundles are preserved")
check(VisibilityPolicy.allowing(running: [], hidden: [own], ownID: own).contains(own), "self always in allowlist")
check(VisibilityPolicy.hiddenOnMenuBar(running: running, groups: groups, ownID: own) == ["quick", "deep"], "main bar keeps both hidden groups hidden")
check(VisibilityPolicy.panelMembers(running: running, groups: groups, state: .collapsed, ownID: own).isEmpty, "closed panel has no entries")
check(VisibilityPolicy.panelMembers(running: running, groups: groups, state: .single, ownID: own) == ["quick"], "single panel has only first group")
check(VisibilityPolicy.panelMembers(running: running, groups: groups, state: .all, ownID: own) == ["quick", "deep"], "double panel has both groups")
check(VisibilityPolicy.panelMembers(running: [own, "new-app"], groups: groups, state: .all, ownID: own).isEmpty, "panel excludes own controller and unconfigured apps")
check(RevealState.collapsed.clicked(count: 1) == .single, "single opens quick")
check(RevealState.single.clicked(count: 1) == .collapsed, "single closes quick")
check(RevealState.collapsed.clicked(count: 2) == .all, "double opens all from collapsed")
check(RevealState.single.clicked(count: 2) == .all, "double opens all from quick")
check(RevealState.all.clicked(count: 2) == .collapsed, "double closes all")
check(RevealState.all.clicked(count: 1) == .single, "single from all keeps quick")
var clicks = ClickRecognizer()
check(clicks.receive(count: 1, now: 10, interval: 0.5) == nil, "first click waits")
check(clicks.flush(now: 10.49) == nil, "does not fire before deadline")
check(clicks.receive(count: 2, now: 10.2, interval: 0.5) == 2, "second click emits only double")
check(clicks.flush(now: 11) == nil, "double cancels pending single")
_ = clicks.receive(count: 1, now: 20, interval: 0.5)
check(clicks.flush(now: 20.5) == 1, "single fires at deadline")
check(clicks.flush(now: 21) == nil, "single fires just once")
_ = clicks.receive(count: 1, now: 30, interval: 0.5)
clicks.cancel()
check(clicks.flush(now: 31) == nil, "right click cancels pending click")
check(clicks.receive(count: 3, now: 40, interval: 0.5) == nil, "triple click does not repeat double")
var forwarded = ClickRecognizer()
check(forwarded.receive(count: 1, now: 50, interval: 0.5) == nil, "forwarded first click waits")
check(forwarded.receive(count: 1, now: 50.12, interval: 0.5) == 2, "two forwarded count=1 actions resolve as double")
check(forwarded.flush(now: 51) == nil, "forwarded double never emits single afterward")
_ = forwarded.receive(count: 1, now: 60, interval: 0.5)
check(forwarded.flush(now: 60.51) == 1, "separate slow click resolves as single")
check(forwarded.receive(count: 1, now: 61, interval: 0.5) == nil, "slow second click starts a fresh gesture")
check(forwarded.flush(now: 61.51) == 1, "slow clicks do not become a double")
let encoded = try JSONEncoder().encode(groups)
let decoded = try JSONDecoder().decode([String: IconGroup].self, from: encoded)
check(decoded == groups, "group assignments round-trip")
print("\(count - failures)/\(count) checks passed")
exit(failures == 0 ? 0 : 1)
