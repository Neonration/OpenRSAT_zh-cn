"""Apply the upstream nonlocal-label fix to the pinned FPC 3.2 branch.

Upstream: 0bdc1fdea4812db1a728171fe9148a5fe95d2209.
Only touches the temporary compiler checkout used by macOS Intel CI.
"""

from pathlib import Path
import sys


def main(root: Path) -> None:
    changes = {
        "nflw.pas": (
            "                        labelsym.nonlocal:=true;\n"
            "                        exclude(current_procinfo.procdef.procoptions,po_inline);",
            "                        exclude(current_procinfo.procdef.procoptions,po_inline);",
        ),
        "pstatmnt.pas": (
            "                       tlabelsym(srsym).nonlocal:=true;\n"
            "                       exclude(current_procinfo.procdef.procoptions,po_inline);\n"
            "                     end;\n"
            "                   if tlabelsym(srsym).nonlocal and\n"
            "                     (current_procinfo.procdef.proctypeoption in [potype_unitinit,potype_unitfinalize]) then\n"
            "                     Message(sym_e_interprocgoto_into_init_final_code_not_allowed);",
            "                       exclude(current_procinfo.procdef.procoptions,po_inline);\n"
            "                       if (current_procinfo.procdef.proctypeoption in [potype_unitinit,potype_unitfinalize]) then\n"
            "                         Message(sym_e_interprocgoto_into_init_final_code_not_allowed);\n"
            "                     end;",
        ),
        "pexpr.pas": (
            "                            tlabelsym(srsym).nonlocal:=true;\n"
            "                            exclude(current_procinfo.procdef.procoptions,po_inline);\n"
            "                          end;\n"
            "                        if tlabelsym(srsym).nonlocal and\n"
            "                          (current_procinfo.procdef.proctypeoption in [potype_unitinit,potype_unitfinalize]) then\n"
            "                          Message(sym_e_interprocgoto_into_init_final_code_not_allowed);",
            "                            exclude(current_procinfo.procdef.procoptions,po_inline);\n"
            "                            if (current_procinfo.procdef.proctypeoption in [potype_unitinit,potype_unitfinalize]) then\n"
            "                              Message(sym_e_interprocgoto_into_init_final_code_not_allowed);\n"
            "                          end;",
        ),
    }
    outputs = []
    for name, (old, new) in changes.items():
        path = root / "compiler" / name
        text = path.read_text(encoding="utf-8")
        if text.count(old) != 1:
            raise ValueError(f"unexpected FPC source in {name}; refusing to patch")
        outputs.append((path, text.replace(old, new, 1)))
    for path, text in outputs:
        path.write_text(text, encoding="utf-8", newline="\n")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: prepare_fpc_darwin.py FPC_SOURCE_DIR")
    main(Path(sys.argv[1]))
