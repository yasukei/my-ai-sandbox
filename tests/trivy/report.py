"""trivy の JSON の結果を集計して表示し、失敗させる条件に当たるかを判定する。

tests/image-scan.sh から呼ばれる。標準ライブラリだけを使う。

使い方:
    python3 tests/trivy/report.py <trivy の JSON の結果>

失敗させる条件（終了コード 1）:
    - 秘密情報が 1 件でも見つかった
    - 修正版がある CRITICAL の脆弱性が 1 件でもある
それ以外（HIGH 以下の脆弱性、設定の問題、ライセンス）は表示だけにする。

結果を読み取れなかったとき（JSON が壊れている、想定したキーが無いなど）は、
判定できないので終了コード 2 で終わる。1 と区別するため、例外で終わらせない。
"""

import json
import sys
from collections import Counter

SEVERITIES = ["CRITICAL", "HIGH", "MEDIUM", "LOW", "UNKNOWN"]
LICENSE_CATEGORIES = [
    "forbidden",
    "restricted",
    "reciprocal",
    "notice",
    "permissive",
    "unencumbered",
    "unknown",
]


def main() -> int:
    if len(sys.argv) != 2:
        print(
            "使い方: python3 tests/trivy/report.py <trivy の JSON の結果>",
            file=sys.stderr,
        )
        return 2
    try:
        return run(sys.argv[1])
    except Exception as e:  # noqa: BLE001 どの例外でも「判定できなかった」として扱う
        print(
            f"\n結果: trivy の結果を読み取れませんでした（{type(e).__name__}: {e}）",
            file=sys.stderr,
        )
        return 2


def is_critical_fixable(v: dict) -> bool:
    return v["Severity"] == "CRITICAL" and bool(v.get("FixedVersion"))


def run(path: str) -> int:
    with open(path, encoding="utf-8") as f:
        report = json.load(f)

    vulns = []  # (target, vulnerability)
    secrets = []  # (target, secret)
    misconfigs = []  # (target, misconfiguration)
    licenses = Counter()

    for result in report.get("Results") or []:
        target = result.get("Target", "")
        for v in result.get("Vulnerabilities") or []:
            vulns.append((target, v))
        for s in result.get("Secrets") or []:
            secrets.append((target, s))
        for m in result.get("Misconfigurations") or []:
            if m.get("Status") == "FAIL":
                misconfigs.append((target, m))
        for lic in result.get("Licenses") or []:
            licenses[lic.get("Category") or "unknown"] += 1

    vuln_total = Counter(v["Severity"] for _, v in vulns)
    vuln_fixable = Counter(v["Severity"] for _, v in vulns if v.get("FixedVersion"))
    misconfig_total = Counter(m["Severity"] for _, m in misconfigs)

    print("\n== 集計（すべての重大度。括弧内は修正版があるもの）")
    print(
        "  脆弱性:     "
        + " / ".join(f"{s} {vuln_total[s]}（{vuln_fixable[s]}）" for s in SEVERITIES)
    )
    print(f"  秘密情報:   {len(secrets)}")
    print(
        "  設定の問題: " + " / ".join(f"{s} {misconfig_total[s]}" for s in SEVERITIES)
    )
    print(
        "  ライセンス: " + " / ".join(f"{c} {licenses[c]}" for c in LICENSE_CATEGORIES)
    )

    print("\n== 秘密情報（1 件でもあれば失敗）")
    if not secrets:
        print("  なし")
    for target, s in secrets:
        print(
            f"  {s.get('Severity', '')}  {s.get('Title', s.get('RuleID', ''))}"
            f"  {target}:{s.get('StartLine', '')}  {s.get('Match', '')}"
        )

    critical_fixable = [(t, v) for t, v in vulns if is_critical_fixable(v)]
    print("\n== 修正版がある CRITICAL の脆弱性（1 件でもあれば失敗）")
    if not critical_fixable:
        print("  なし")
    for target, v in critical_fixable:
        print_vuln(target, v)

    high_or_above = [
        (t, v)
        for t, v in vulns
        if v["Severity"] in ("CRITICAL", "HIGH") and not is_critical_fixable(v)
    ]
    # 修正版があるものを先に、同じなら重大度の高い順に並べる
    high_or_above.sort(
        key=lambda tv: (
            not tv[1].get("FixedVersion"),
            SEVERITIES.index(tv[1]["Severity"]),
        )
    )
    print("\n== そのほかの HIGH 以上の脆弱性（表示のみ）")
    if not high_or_above:
        print("  なし")
    for target, v in high_or_above:
        print_vuln(target, v)

    print("\n== 設定の問題（表示のみ）")
    if not misconfigs:
        print("  なし")
    for target, m in misconfigs:
        print(f"  {m['Severity']}  {m.get('ID', '')}  {m.get('Title', '')}")

    failed = bool(secrets or critical_fixable)
    print()
    if failed:
        print("結果: 失敗（秘密情報、または修正版がある CRITICAL の脆弱性があります）")
    else:
        print("結果: 成功（秘密情報と、修正版がある CRITICAL の脆弱性はありません）")
    return 1 if failed else 0


def print_vuln(target: str, v: dict) -> None:
    fixed = v.get("FixedVersion") or "修正版なし"
    print(
        f"  {v['Severity']:<8} {v.get('PkgName', '')}  {v.get('InstalledVersion', '')}"
        f" -> {fixed}  {v.get('VulnerabilityID', '')}  （{target}）"
    )


if __name__ == "__main__":
    sys.exit(main())
