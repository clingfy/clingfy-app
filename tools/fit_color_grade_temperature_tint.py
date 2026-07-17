"""Re-derives the calibrated color-grade constants in
windows/runner/Capture/Export/color_grade.{h,cpp} from the golden fixture.

Run after regenerating windows/runner_tests/fixtures/color_grade_golden.json
(macos RunnerTests/ColorGradeGoldenDumpTests):

    python tools/fit_color_grade_temperature_tint.py

Prints the saturation lumas and the temperature/tint model constants
(kTempTintBasis / kTempTintBasisInv / kLogConeTemp / kLogConeTint /
kLogConeCross) plus a full validation table; paste the constants into
color_grade.{h,cpp} when they change.

Model background (see the derivation note in color_grade.cpp): every golden
temperature/tint case is an exactly linear 3x3 transform on linear sRGB and
all cases share one eigenbasis to machine precision — Core Image applies a
von-Kries-style diagonal scaling in one fixed cone basis that matches no
published CAT. In that basis, ln(scale) per channel is fit as an exact
quartic per slider axis plus low-order cross terms least-squared through the
composite cases (the s=-1 composite contributes its white response, which is
all that a rank-1 saturation chain observes).

Requires numpy. Expected result: OVERALL worst well under the golden test's
2e-3 tolerance (2026-07 fixture: 1.7e-3).
"""

import json
import os
import numpy as np

FIXTURE = os.path.join(os.path.dirname(__file__), "..", "windows",
                       "runner_tests", "fixtures", "color_grade_golden.json")


def srgb_to_linear(v):
    v = np.asarray(v, dtype=float)
    return np.where(np.abs(v) <= 0.04045,
                    v / 12.92,
                    np.sign(v) * ((np.abs(v) + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(v):
    v = np.asarray(v, dtype=float)
    return np.where(np.abs(v) <= 0.0031308,
                    v * 12.92,
                    np.sign(v) * (1.055 * np.abs(v) ** (1 / 2.4) - 0.055))


def exposure_matrix(e):
    return np.eye(3) * (2.0 ** (1.5 * e)) if e else np.eye(3)


def fit_matrix(inputs, outputs):
    A = np.hstack([inputs, np.ones((len(inputs), 1))])
    W, *_ = np.linalg.lstsq(A, outputs, rcond=None)
    return W[:3].T


def cpp_rows(name, mat):
    print(f"{name} = {{")
    for row in mat:
        print("    {" + ", ".join(repr(float(x)) for x in row) + "},")
    print("}")


def main():
    with open(FIXTURE, encoding="utf-8") as f:
        fx = json.load(f)
    inputs = srgb_to_linear(np.array(fx["inputs"]))

    raw = {}
    for case in fx["cases"]:
        g = case["grade"]
        key = (g["exposure"], g["contrast"], g["saturation"],
               g["temperature"], g["tint"])
        raw[key] = (fit_matrix(inputs,
                               srgb_to_linear(np.array(case["outputs"]))),
                    case)

    # ---- saturation lumas from the pure-s cases ----------------------------
    lumas = []
    for (e, c, s, t, n), (M, _) in raw.items():
        if e == 0 and c == 0 and t == 0 and n == 0 and s != 0:
            k = 1.0 + s
            lumas.append(((M - k * np.eye(3)) / (1.0 - k)).mean(axis=0))
    luma = np.mean(lumas, axis=0)
    # Renormalize to sum exactly 1 so gray stays a fixed point of the
    # saturation matrix (the raw fit is off by fixture render noise, ~5e-8).
    luma = luma / luma.sum()

    def cs_matrix_off(c, s):
        k = 1.0 + s
        sat = k * np.eye(3) + (1.0 - k) * np.outer(np.ones(3), luma)
        kc = 1.0 + 0.5 * c
        return (np.eye(3) * kc) @ sat, np.full(3, 0.5 * (1 - kc))

    # ---- temperature/tint extraction ---------------------------------------
    mats = {}
    white_resp = {}
    for (e, c, s, t, n), (M_total, case) in raw.items():
        if t == 0 and n == 0:
            continue
        pre, off = cs_matrix_off(c, s)
        pre = pre @ exposure_matrix(e)
        if abs(np.linalg.det(pre)) > 1e-9:
            mats[(t, n)] = M_total @ np.linalg.inv(pre)
        else:
            # s = -1 collapses the chain onto span{(1,1,1)}: the case observes
            # only M_tt @ (1,1,1). Regress that white response directly.
            lin_out = srgb_to_linear(np.array(case["outputs"]))
            scal = (inputs @ pre[0]) + off[0]
            white_resp[(t, n)] = (lin_out * scal[:, None]).sum(axis=0) / \
                (scal ** 2).sum()

    _, V = np.linalg.eig(mats[(-1.0, 0.0)])
    V = np.real(V)
    for j in range(3):
        col = V[:, j]
        V[:, j] = col / np.linalg.norm(col) * \
            np.sign(col[np.argmax(np.abs(col))])
    Vinv = np.linalg.inv(V)
    c0 = Vinv @ np.ones(3)

    diags = {k: np.diag(Vinv @ M @ V) for k, M in mats.items()}
    for k, w in white_resp.items():
        diags[k] = (Vinv @ w) / c0

    grid = np.array([-1.0, -0.5, 0.5, 1.0])
    basis_axis = np.array([[x, x ** 2, x ** 3, x ** 4] for x in grid])
    coef_t = np.linalg.solve(
        basis_axis, np.array([np.log(diags[(t, 0.0)]) for t in grid]))
    coef_n = np.linalg.solve(
        basis_axis, np.array([np.log(diags[(0.0, n)]) for n in grid]))

    def axis_val(coef, x):
        return np.array([x, x ** 2, x ** 3, x ** 4]) @ coef

    def cross_basis(t, n):
        return np.array([t * n, t * t * n, t * n * n, t * t * n * n])

    comps = sorted(k for k in diags if k[0] != 0 and k[1] != 0)
    A = np.array([cross_basis(t, n) for t, n in comps])
    B = np.array([np.log(diags[(t, n)]) - axis_val(coef_t, t) -
                  axis_val(coef_n, n) for t, n in comps])
    cross, *_ = np.linalg.lstsq(A, B, rcond=None)

    def tt_matrix(t, n):
        if t == 0 and n == 0:
            return np.eye(3)
        ln_d = axis_val(coef_t, t) + axis_val(coef_n, n) + \
            cross_basis(t, n) @ cross
        return V @ np.diag(np.exp(ln_d)) @ Vinv

    # ---- validate -----------------------------------------------------------
    overall = 0.0
    for (e, c, s, t, n), (_, case) in sorted(raw.items()):
        pre, off = cs_matrix_off(c, s)
        pre = pre @ exposure_matrix(e)
        Mtt = tt_matrix(t, n)
        out = linear_to_srgb(inputs @ (Mtt @ pre).T + Mtt @ off)
        worst = np.max(np.abs(out - np.array(case["outputs"])))
        overall = max(overall, worst)
        tag = "FAIL" if worst > 2e-3 else "ok  "
        print(f"{tag} e={e:+.2f} c={c:+.2f} s={s:+.2f} t={t:+.2f} "
              f"n={n:+.2f}  worst={worst:.6f}")
    print(f"\nOVERALL worst = {overall:.6f} (golden tolerance 2e-3)\n")

    print("=== paste into color_grade.h ===")
    print(f"kSaturationLumaR = {luma[0]!r}")
    print(f"kSaturationLumaG = {luma[1]!r}")
    print(f"kSaturationLumaB = {luma[2]!r}")
    print("\n=== paste into color_grade.cpp ===")
    cpp_rows("kTempTintBasis", V)
    cpp_rows("kTempTintBasisInv", Vinv)
    cpp_rows("kLogConeTemp", coef_t.T)
    cpp_rows("kLogConeTint", coef_n.T)
    cpp_rows("kLogConeCross", cross.T)


if __name__ == "__main__":
    main()
