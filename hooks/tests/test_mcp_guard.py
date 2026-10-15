#!/usr/bin/env python3
"""Tests for hooks/craft-mcp-guard.py and its table hooks/risky-tools.json
(plain unittest; run: python3 hooks/tests/test_mcp_guard.py).

The hook is run the way Claude Code runs it: a subprocess that reads the hook JSON on stdin and prints
either nothing (silent) or one "ask" decision. HOME and the workspace are fake (/Users/you).
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
HOOKS_DIR = os.path.normpath(os.path.join(HERE, ".."))
HOOK = os.path.join(HOOKS_DIR, "craft-mcp-guard.py")
TABLE = os.path.join(HOOKS_DIR, "risky-tools.json")
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
HOME = "/Users/you"
WS = HOME + "/craft-workspace"
ENV = dict(os.environ, HOME=HOME)
APPS = ("wordcraft gridcraft deckcraft pdfcraft photocraft vectorcraft designcraft cadcraft figcraft "
        "filmcraft effectcraft lightcraft soundcraft").split()


def T(app, tool):
    return "mcp__%s__%s" % (app, tool)


def inside(app, *parts):
    return "/".join([WS, app] + list(parts))


# (tool_name, tool_input, text that must appear in the reason)
ASK = [
    # --- side effects outside the document: pdfcraft
    (T("pdfcraft", "doc_print"), {"doc": 1}, "printer"),
    (T("pdfcraft", "link_open"), {"doc": 1, "page": 1, "index": 1}, "link"),
    (T("pdfcraft", "doc_protect"), {"doc": 1, "open_password": "x"}, "password"),
    (T("pdfcraft", "doc_unprotect"), {"doc": 1}, "password"),
    (T("pdfcraft", "redact_apply"), {"doc": 1}, "redaction"),
    (T("pdfcraft", "doc_remove_hidden"), {"doc": 1}, "hidden"),
    (T("pdfcraft", "content_delete"), {"doc": 1, "page": 1, "index": 0}, "delete"),
    (T("pdfcraft", "js_run"), {"doc": 1, "script": "app.alert(1)"}, "JavaScript"),
    (T("pdfcraft", "js_set_document_script"), {"doc": 1, "name": "a", "script": "1"}, "JavaScript"),
    (T("pdfcraft", "form_set_script"), {"doc": 1, "field": "f", "event": "validate", "script": "1"}, "JavaScript"),
    (T("pdfcraft", "js_enabled"), {"enabled": True}, "JavaScript"),
    (T("pdfcraft", "sign_document"), {"doc": 1, "id": "keychain:me"}, "sign"),
    (T("pdfcraft", "sign_id_create"), {"name": "me", "path": inside("pdfcraft", "me.p12")}, "digital ID"),
    (T("pdfcraft", "sign_trust"), {"paths": [inside("pdfcraft", "a.cer")]}, "trusted"),
    (T("pdfcraft", "sign_keychain_ids"), {}, "keychain"),
    (T("pdfcraft", "action_run"), {"action": "x", "folder": inside("pdfcraft", "in")}, "Action Wizard"),
    # --- side effects outside the document: lightcraft (cmd_* wrappers, runners, batches)
    (T("lightcraft", "cmd_photo_deletePermanently"), {}, "permanently"),
    (T("lightcraft", "cmd_library_emptyRecentlyDeleted"), {}, "Recently Deleted"),
    (T("lightcraft", "cmd_photo_editExternal"), {"ids": [1]}, "external editor"),
    (T("lightcraft", "cmd_export_addToPhotos"), {"paths": [inside("lightcraft", "out", "a.jpg")]}, "Apple Photos"),
    (T("lightcraft", "cmd_denoise_models_download"), {"id": "m", "acknowledged": True}, "downloads"),
    (T("lightcraft", "cmd_faces_models_download"), {"id": "m", "acknowledged": True}, "downloads"),
    (T("lightcraft", "cmd_segment_model_download"), {"acknowledged": True}, "downloads"),
    (T("lightcraft", "cmd_metadata_downloadPlaceNames"), {}, "downloads"),
    (T("lightcraft", "cmd_photo_moveToFolder"), {"folder": inside("lightcraft", "out")}, "moves"),
    (T("lightcraft", "cmd_folder_move"), {"path": inside("lightcraft", "a"), "into": inside("lightcraft", "b")}, "moves"),
    (T("lightcraft", "command_run"), {"id": "photo.deletePermanently", "params": {"ids": [1]}}, "permanently"),
    (T("lightcraft", "run_command"), {"command": "library.emptyRecentlyDeleted"}, "Recently Deleted"),
    (T("lightcraft", "command_batch"),
     {"steps": [{"id": "photo.rate", "params": {"rating": 3}}, {"id": "export.addToPhotos", "params": {}}]},
     "Apple Photos"),
    (T("lightcraft", "command_run"), {"id": "metadata.downloadPlaceNames"}, "downloads"),
    (T("pdfcraft", "command_run"), {"id": "doc.print", "params": {}}, "print"),
    (T("pdfcraft", "command_batch"), {"steps": [{"id": "page.rotate"}, {"id": "doc_protect"}]}, "password"),
    (T("effectcraft", "run_script"), {"code": "app.project.items.length"}, "JavaScript"),
    (T("deckcraft", "call_app"), {"method": "ui.click", "params": {}}, "control-channel"),
    (T("photocraft", "control_call"), {"method": "x", "params": {}}, "control-protocol"),
    (T("filmcraft", "ui_control"), {"method": "x", "params": {}}, "control call"),
    # --- save-style tools without an explicit path (overwrite in place)
    (T("wordcraft", "save_document"), {}, "without an explicit path"),
    (T("gridcraft", "save_workbook"), {}, "without an explicit path"),
    (T("deckcraft", "save_presentation"), {}, "without an explicit path"),
    (T("vectorcraft", "save_file"), {}, "without an explicit path"),
    (T("designcraft", "save_document"), {}, "without an explicit path"),
    (T("cadcraft", "save"), {}, "without an explicit path"),
    (T("figcraft", "save_file"), {}, "without an explicit path"),
    (T("effectcraft", "save_project"), {}, "without an explicit path"),
    (T("soundcraft", "save_session"), {}, "without an explicit path"),
    (T("photocraft", "doc_save"), {"index": 0}, "without an explicit path"),
    (T("pdfcraft", "doc_save"), {"doc": 1}, "without an explicit path"),
    (T("pdfcraft", "doc_save"), {"doc": 1, "path": ""}, "without an explicit path"),
    (T("pdfcraft", "doc_save"), {"doc": 1, "path": "   "}, "without an explicit path"),
    (T("pdfcraft", "doc_save"), {"doc": 1, "path": None}, "without an explicit path"),
    (T("vectorcraft", "export"), {"format": "svg"}, "without an explicit path"),
    (T("deckcraft", "export"), {"format": "pdf"}, "without an explicit path"),
    (T("figcraft", "export"), {"format": "png"}, "without an explicit path"),
    (T("lightcraft", "export"), {"id": 1, "format": "jpg"}, "without an explicit path"),
    (T("soundcraft", "bounce_mix"), {"format": "wav"}, "without an explicit path"),
    (T("vectorcraft", "command_run"), {"id": "document.save", "params": {}}, "without an explicit path"),
    (T("wordcraft", "execute"), {"command": "file.save", "params": {}}, "without an explicit path"),
    # --- risky arguments
    (T("lightcraft", "import"), {"paths": [inside("lightcraft", "in", "a.dng")], "mode": "move"}, "moves the original"),
    (T("lightcraft", "import"), {"paths": [inside("lightcraft", "in")], "mode": "MOVE"}, "moves the original"),
    (T("lightcraft", "command_run"),
     {"id": "library.import", "params": {"paths": [inside("lightcraft", "in")], "mode": "move"}}, "moves the original"),
    (T("lightcraft", "export"), {"id": 1, "path": inside("lightcraft", "out", "a.jpg"), "conflict": "overwrite"}, "overwrite"),
    (T("lightcraft", "export"), {"id": 1, "path": inside("lightcraft", "out", "a.jpg"), "addToPhotos": True}, "Apple Photos"),
    (T("lightcraft", "export"), {"ids": [1], "dir": inside("lightcraft", "out"), "addToPhotos": "true"}, "Apple Photos"),
    (T("soundcraft", "save_session"), {"path": inside("soundcraft", "out", "a.scraft"), "replace": True}, "existing file"),
    (T("wordcraft", "execute"), {"command": "x", "params": {"conflict": "overwrite"}}, "overwrite"),
    (T("gridcraft", "execute_command"), {"command": "x", "params": {"overwrite": True}}, "overwrite"),
    # --- paths that do not resolve under <workspace>/<app>
    (T("wordcraft", "open_document"), {"path": "/etc/passwd"}, "is not under"),
    (T("wordcraft", "open_document"), {"path": "~/Documents/a.docx"}, "is not under"),
    (T("wordcraft", "open_document"), {"path": "~root/a.docx"}, "is not under"),
    (T("wordcraft", "open_document"), {"path": "../a.docx"}, "is not under"),
    (T("wordcraft", "open_document"), {"path": "./../a.docx"}, "is not under"),
    (T("wordcraft", "open_document"), {"path": inside("wordcraft", "in", "..", "..", "gridcraft", "a.docx")}, "is not under"),
    (T("wordcraft", "open_document"), {"path": inside("gridcraft", "in", "a.docx")}, "is not under"),
    (T("wordcraft", "open_document"), {"path": WS + "/wordcraft-evil/a.docx"}, "is not under"),
    (T("wordcraft", "open_document"), {"path": WS}, "is not under"),
    (T("wordcraft", "open_document"), {"path": "file:///etc/hosts"}, "is not under"),
    (T("wordcraft", "open_document"), {"path": "file://example.com/share/a.docx"}, "is not under"),
    (T("wordcraft", "open_document"), {"path": "file://" + inside("wordcraft", "%2e%2e", "gridcraft", "a")}, "is not under"),
    (T("wordcraft", "save_document"), {"path": "/tmp/a.docx"}, "is not under"),
    (T("lightcraft", "import"), {"paths": [inside("lightcraft", "in"), "/srv/photos/raw"]}, "is not under"),
    (T("pdfcraft", "page_insert_file"), {"doc": 1, "at": 1, "path": "/tmp/../etc/x.pdf"}, "is not under"),
    (T("vectorcraft", "command_run"), {"id": "x", "params": {"out": {"dir": "../../x"}}}, "is not under"),
    (T("lightcraft", "command_batch"), {"steps": [{"id": "photo.rate"}, {"id": "x", "params": {"path": "/etc/x"}}]}, "is not under"),
    (T("soundcraft", "import_audio"), {"path": "~/Music/a.wav"}, "is not under"),
    (T("figcraft", "export"), {"path": "/Users/you/Desktop/a.png"}, "is not under"),
    (T("designcraft", "place_image"), {"path": "/Users/you/Pictures/a.png", "x": 0, "y": 0}, "is not under"),
    (T("cadcraft", "open"), {"path": ".."}, "is not under"),
    (T("deckcraft", "insert_picture"), {"path": "a/../../b.png"}, "is not under"),
    # --- command ids the skills' Never lists name (R1-INJECT-1, R1-HOOK-4)
    (T("photocraft", "command_run"), {"id": "plugin.run"}, "plug-in"),
    (T("photocraft", "command_run"), {"id": "actions.play"}, "action"),
    (T("photocraft", "command_run"), {"id": "file.printOneCopy"}, "print"),
    (T("photocraft", "command_batch"), {"steps": [{"id": "plugin.install"}]}, "plug-in"),
    (T("gridcraft", "execute_command"), {"command": "link.open"}, "link"),
    (T("gridcraft", "execute_command"), {"command": "review.protectWorkbook"}, "password"),
    (T("effectcraft", "command_run"), {"id": "file.installScript"}, "script"),
    (T("effectcraft", "script_ui"), {"action": "click", "widget": "ok"}, "dialogs"),
    (T("effectcraft", "set_property"), {"layer": 1, "path": "transform/position", "expression": "time*10"}, "expression"),
    (T("figcraft", "run_command"), {"command": "plugin.run"}, "plug-in"),
    (T("figcraft", "batch"), {"commands": [{"command": "library.publishToServer"}]}, "publish"),
    (T("filmcraft", "command_run"), {"id": "tts.downloadVoices"}, "voice"),
    (T("filmcraft", "command_run"), {"id": "audio.voiceover.start"}, "microphone"),
    (T("filmcraft", "command_run"), {"id": "media.makeOffline", "params": {"deleteFiles": True}}, "deletes the media"),
    (T("filmcraft", "command_run"), {"id": "file.closeProject", "params": {"force": True}}, "discarding"),
    (T("filmcraft", "command_run"), {"id": "file.closeAllProjects", "params": {"force": True}}, "discarding"),
    (T("soundcraft", "execute"), {"command": "file.print_score"}, "print"),
    (T("soundcraft", "execute"), {"command": "file.send_to_sibelius"}, "Sibelius"),
    (T("wordcraft", "execute"), {"command": "file.encrypt"}, "password"),
    (T("wordcraft", "execute"), {"command": "file.share"}, "sharing"),
    (T("lightcraft", "run_command"), {"command": "library.autoImportScan"}, "watched folder"),
    (T("lightcraft", "cmd_library_autoImportScan"), {}, "watched folder"),
    (T("lightcraft", "command_run"), {"id": "photo.rename", "params": {"template": "{date}"}}, "renames"),
    (T("lightcraft", "cmd_photo_rename"), {"template": "{date}"}, "renames"),
    (T("lightcraft", "cmd_folder_synchronize"), {"path": inside("lightcraft", "in")}, "sync"),
    (T("pdfcraft", "doc_close"), {"doc": 1, "discard_changes": True}, "discards"),
    # --- pdfcraft actions and links that persist in the saved PDF (R1-INJECT-2)
    (T("pdfcraft", "form_set_actions"), {"doc": 1, "field": "f", "actions": [{"trigger": "mouse_up", "submit": "https://x.example/"}]}, "submit"),
    (T("pdfcraft", "form_set_actions"), {"doc": 1, "field": "f", "actions": [{"trigger": "mouse_up", "javascript": "app.alert(1)"}]}, "JavaScript"),
    (T("pdfcraft", "form_set_actions"), {"doc": 1, "field": "f", "actions": [{"trigger": "mouse_up", "menu": "Print"}]}, "menu"),
    (T("pdfcraft", "command_run"), {"id": "form.setActions", "params": {"actions": [{"submit": "https://x.example/"}]}}, "submit"),
    (T("pdfcraft", "link_add"), {"doc": 1, "page": 1, "rect": [0, 0, 1, 1], "url": "https://example.com/a/../b"}, "web address"),
    (T("pdfcraft", "link_edit"), {"doc": 1, "page": 1, "index": 0, "url": "https://example.com/"}, "web address"),
    (T("pdfcraft", "links_from_urls"), {"doc": 1}, "clickable"),
    # --- script text in a runner (R1-HOOK-1, R1-INJECT-3, B1-HOOK-1)
    (T("designcraft", "batch"), {"script": "file.print {}"}, "print"),
    (T("designcraft", "batch"), {"script": "file.save {}"}, "without an explicit path"),
    (T("designcraft", "batch"), {"script": "frame.create {\"rect\":[0,0,1,1]}\nfile.print {}"}, "print"),
    (T("designcraft", "batch"), {"commands": ["file.print {}"]}, "print"),
    (T("designcraft", "batch"), {"steps": ["file.print {\"x\":1}"]}, "print"),
    (T("designcraft", "batch"), {"script": "frame.create {}; file.print"}, "print"),
    (T("designcraft", "batch"), {"script": "export_png {\"page\":1}"}, "without an explicit path"),
    (T("designcraft", "batch"), {"script": "export_png {\"page\":1,\"path\":\"$0.path\"}"}, "placeholder"),
    (T("designcraft", "batch"), {"script": "place.image {\"path\":\"/Users/you/Desktop/x.png\"}"}, "is not under"),
    (T("designcraft", "execute"), {"command": "file.print {}"}, "print"),
    # --- CADCraft typed commands (R1-SKILLS-3, B1-SKILLS-1)
    (T("cadcraft", "command_line"), {"text": "PLOT"}, "print"),
    (T("cadcraft", "command_line"), {"text": "-PLOT"}, "print"),
    (T("cadcraft", "command_line"), {"text": "exportpdf"}, "PDF"),
    (T("cadcraft", "command_line"), {"text": "w " + inside("cadcraft", "in", "plan.dxf")}, "writes blocks"),
    (T("cadcraft", "command_line"), {"text": "wblock /private/tmp/outside.dxf"}, "is not under"),
    (T("cadcraft", "command_line"), {"text": "export /Users/you/Desktop/x.dxf"}, "is not under"),
    (T("cadcraft", "command_line"), {"text": "(load \"x.lsp\")"}, "LISP"),
    (T("cadcraft", "script"), {"text": "line 0,0 10,10\n-PLOT"}, "print"),
    (T("cadcraft", "script"), {"text": "ATTACH /Users/you/Documents/block.dxf 0,0"}, "is not under"),
    (T("cadcraft", "execute"), {"command": "plot"}, "print"),
    (T("cadcraft", "execute"), {"command": "publish"}, "PDF"),
    (T("cadcraft", "execute"), {"command": "wblock"}, "writes blocks"),
    (T("cadcraft", "execute"), {"command": "w"}, "writes blocks"),
    # --- export-style ids without a path (B1-INJECT-1, B1-SKILLS-2)
    (T("designcraft", "execute"), {"command": "file.exportPdf"}, "without an explicit path"),
    (T("gridcraft", "execute_command"), {"command": "file.exportPdf"}, "without an explicit path"),
    (T("filmcraft", "command_run"), {"id": "file.exportMedia"}, "without an explicit path"),
    (T("filmcraft", "command_run"), {"id": "file.saveAs", "params": {}}, "without an explicit path"),
    (T("soundcraft", "execute"), {"command": "file.export_sibelius"}, "Sibelius"),
    (T("pdfcraft", "doc_export_text"), {"doc": 1}, "without an explicit path"),
    # --- relative or placeholder save paths (R1-INJECT-7, B1-SKILLS-3)
    (T("designcraft", "export_png"), {"page": 1, "path": "export.png"}, "relative"),
    (T("wordcraft", "save_document"), {"path": "report.docx"}, "relative"),
    (T("gridcraft", "save_workbook"), {"path": "out/x.xlsx"}, "relative"),
    (T("wordcraft", "open_document"), {"path": "in/a.docx"}, "relative path"),
    (T("wordcraft", "open_document"), {"path": "./in/a.docx"}, "relative path"),
    # --- saves into in/ (R1-INJECT-8, R1-SKILLS-1); existing files are tested in ExistingTargetTests
    (T("pdfcraft", "doc_save"), {"doc": 1, "path": inside("pdfcraft", "in", "original.pdf")}, "input copies"),
    (T("wordcraft", "save_document"), {"path": inside("wordcraft", "in", "letter.docx")}, "input copies"),
    (T("lightcraft", "export"), {"ids": [1], "dir": inside("lightcraft", "in")}, "input copies"),
    # --- leading whitespace does not hide a path (B1-INJECT-4)
    (T("filmcraft", "media_import"), {"paths": [" /Users/you/Movies/secret.mov"]}, "is not under"),
    (T("filmcraft", "media_import"), {"paths": ["\t/Users/you/Movies/secret.mov"]}, "is not under"),
    (T("wordcraft", "open_document"), {"path": "/etc/hosts\n"}, "is not under"),
    # --- a newline inside a path does not hide it (R1-HOOK-7)
    (T("wordcraft", "open_document"), {"path": inside("wordcraft", "a\n", "..", "..", "..", "..", "etc", "hosts")}, "is not under"),
    # --- AutoCAD ATTACH without the X prefix (B1-INJECT-1)
    (T("cadcraft", "command_line"), {"text": "ATTACH block 0,0"}, "attach"),
    # --- links that stay in the saved document (B1-INJECT-3)
    (T("designcraft", "execute"), {"command": "hyperlink.create", "params": {"url": "https://x.example/"}}, "web link"),
    (T("designcraft", "execute"), {"command": "hyperlink.create", "params": {"email": "a@x.example"}}, "e-mail link"),
    (T("deckcraft", "run_command"), {"command": "hyperlink.create", "params": {"url": "https://x.example/"}}, "web link"),
    # --- package copies in DeckCraft as in DesignCraft (B1-INJECT-4)
    (T("deckcraft", "run_command"), {"command": "file.package", "params": {}}, "package"),
    # --- UI-level tools that can print or save (R1-HOOK-4, B1-HOOK-2)
    (T("effectcraft", "command_run"), {"id": "prop.setExpression", "params": {"expression": "1"}}, "JavaScript"),
    (T("soundcraft", "menu_invoke"), {"path": "File > Print..."}, "menu"),
    (T("soundcraft", "batch"), {"calls": [{"tool": "menu_invoke", "args": {"path": "File > Print..."}}]}, "menu"),
    (T("designcraft", "key"), {"key": "cmd+p"}, "keyboard"),
    (T("designcraft", "dialog_confirm"), {}, "dialog"),
    (T("vectorcraft", "invoke_menu"), {"path": "File > Print"}, "menu"),
    # --- output folders of any tool must not be in/ (B1-SKILLS-1)
    (T("pdfcraft", "doc_split"), {"doc": 1, "out_dir": inside("pdfcraft", "in")}, "input copies"),
    (T("pdfcraft", "page_extract"), {"doc": 1, "pages": "1", "out_dir": inside("pdfcraft", "in")}, "input copies"),
    (T("pdfcraft", "page_extract"), {"doc": 1, "pages": "1", "out": inside("pdfcraft", "in", "p1.pdf")}, "input copies"),
]

SILENT = [
    # --- inside the fence (explicit paths)
    (T("wordcraft", "save_document"), {"path": inside("wordcraft", "out", "a-20261014-1200.docx")}),
    (T("wordcraft", "open_document"), {"path": inside("wordcraft", "in", "a.docx")}),
    (T("wordcraft", "open_document"), {"path": inside("wordcraft", "in") + "/"}),
    (T("wordcraft", "open_document"), {"path": inside("wordcraft")}),
    (T("wordcraft", "open_document"), {"path": inside("wordcraft", "in", "..", "in", "a.docx")}),
    (T("gridcraft", "open_workbook"), {"path": "./in/a.xlsx"}),
    (T("wordcraft", "open_document"), {"path": "file://" + inside("wordcraft", "in", "a.docx")}),
    (T("wordcraft", "open_document"), {"path": "file://localhost" + inside("wordcraft", "in", "a.docx")}),
    (T("wordcraft", "open_document"), {"path": "~/craft-workspace/wordcraft/in/a.docx"}),
    (T("gridcraft", "open_workbook"), {"path": "in/a.xlsx"}),
    (T("lightcraft", "import"), {"paths": ["in/IMG_0001.jpg"]}),
    (T("pdfcraft", "doc_save"), {"doc": 1, "path": inside("pdfcraft", "out", "a.pdf")}),
    (T("lightcraft", "export"), {"id": 1, "path": inside("lightcraft", "out", "a.jpg")}),
    (T("lightcraft", "export"), {"ids": [1, 2], "dir": inside("lightcraft", "out")}),
    (T("lightcraft", "export"), {"id": 1, "path": inside("lightcraft", "out", "a.jpg"), "addToPhotos": False}),
    (T("lightcraft", "export"), {"id": 1, "path": inside("lightcraft", "out", "a.jpg"), "conflict": "rename"}),
    (T("lightcraft", "import"), {"paths": [inside("lightcraft", "in", "a.dng")], "mode": "copy"}),
    (T("lightcraft", "import"), {"paths": [inside("lightcraft", "in", "a.dng")], "mode": "add"}),
    (T("lightcraft", "import"), {"paths": [inside("lightcraft", "in")]}),
    (T("soundcraft", "save_session"), {"path": inside("soundcraft", "out", "a.scraft"), "replace": False}),
    (T("soundcraft", "bounce_mix"), {"path": inside("soundcraft", "out", "mix.wav"), "format": "wav"}),
    (T("deckcraft", "export"), {"path": inside("deckcraft", "out", "a.pdf"), "format": "pdf"}),
    (T("vectorcraft", "save_file"), {"path": inside("vectorcraft", "out", "a.vectorcraft")}),
    (T("wordcraft", "execute"), {"command": "file.save", "params": {"path": inside("wordcraft", "out", "a.docx")}}),
    (T("vectorcraft", "command_run"), {"id": "document.save", "params": {"path": inside("vectorcraft", "out", "a.svg")}}),
    # --- ordinary editing and read-only tools
    (T("wordcraft", "new_document"), {"template": "blank"}),
    (T("wordcraft", "inspect_document"), {}),
    (T("wordcraft", "list_commands"), {"query": "/etc"}),
    (T("wordcraft", "execute"), {"command": "format.bold", "params": {}}),
    (T("wordcraft", "batch"), {"commands": [{"command": "text.newParagraph"}, {"command": "para.style", "params": {"style": "Heading 1"}}]}),
    (T("lightcraft", "query_photos"), {"limit": 10}),
    (T("lightcraft", "cmd_photo_rate"), {"rating": 4}),
    (T("lightcraft", "command_run"), {"id": "photo.rate", "params": {"rating": 4}}),
    (T("lightcraft", "command_run"), {"id": "photo.delete", "params": {"ids": [1]}}),
    (T("lightcraft", "set_develop"), {"values": {"light.exposure": 0.5}}),
    (T("pdfcraft", "doc_open"), {"path": inside("pdfcraft", "in", "a.pdf")}),
    (T("pdfcraft", "text_extract"), {"doc": 1, "pages": "1-3"}),
    (T("pdfcraft", "printers"), {}),
    (T("pdfcraft", "print_readiness"), {"doc": 1}),
    (T("pdfcraft", "redact_mark"), {"doc": 1, "find": "SSN", "words": ["/etc/passwd"]}),
    (T("pdfcraft", "link_add"), {"doc": 1, "page": 1, "rect": [0, 0, 1, 1], "to_page": 3}),
    (T("pdfcraft", "form_set_actions"), {"doc": 1, "field": "f", "actions": [{"trigger": "mouse_up", "reset": []}]}),
    (T("pdfcraft", "form_set_actions"), {"doc": 1, "field": "f", "actions": [{"trigger": "mouse_up", "show": ["g"]}]}),
    (T("pdfcraft", "form_set_actions"), {"doc": 1, "field": "f", "actions": [{"trigger": "mouse_up", "hide": ["g"]}]}),
    (T("pdfcraft", "doc_close"), {"doc": 1}),
    (T("designcraft", "batch"), {"script": "frame.create {\"rect\":[0,0,1,1]}"}),
    (T("designcraft", "batch"), {"script": "save_document {\"path\":\"%s\"}" % inside("designcraft", "out", "a.dc")}),
    (T("cadcraft", "command_line"), {"text": "line 0,0 10,0 10,5 c"}),
    (T("cadcraft", "command_line"), {"text": "circle 5,2.5 1"}),
    (T("cadcraft", "command_line"), {"text": "rectang 0,0 4,3"}),
    (T("cadcraft", "command_line"), {"text": "offset 1"}),
    (T("cadcraft", "command_line"), {"text": "zoom e"}),
    (T("cadcraft", "command_line"), {"text": "zoom w 0,0 5,5"}),
    (T("cadcraft", "execute"), {"command": "zoom", "params": {"mode": "extents"}}),
    (T("filmcraft", "command_run"), {"id": "file.exportMedia", "params": {"path": inside("filmcraft", "out", "a.mp4")}}),
    (T("lightcraft", "command_run"), {"id": "export.presets"}),
    (T("effectcraft", "set_property"), {"layer": 1, "path": "transform/position", "value": [1, 2], "expression": None}),
    (T("pdfcraft", "js_enabled"), {}),
    (T("gridcraft", "write_range"), {"range": "A1:B2", "values": [["/etc", "../x"], ["~/y", "=A1/B1"]]}),
    (T("gridcraft", "set_cell"), {"cell": "A1", "input": "/usr/bin"}),
    (T("deckcraft", "add_text_box"), {"text": "../../etc/passwd", "x": 0, "y": 0, "w": 1, "h": 1}),
    (T("wordcraft", "type_text"), {"text": "See /etc/hosts or ../x or ~/y or file:///z"}),
    (T("wordcraft", "type_text"), {"text": "Wait... what? a..b"}),
    (T("vectorcraft", "draw_path"), {"d": "M 0 0 L /10 10", "fill": "#fff"}),
    (T("designcraft", "set_story_text"), {"story": 1, "text": "/Library/Fonts/x.otf"}),
    (T("pdfcraft", "doc_set_info"), {"doc": 1, "key": "Title", "value": "/etc/x"}),
    (T("effectcraft", "set_property"), {"layer": 1, "path": "transform/position", "value": [1, 2]}),
    (T("effectcraft", "get_layer"), {"comp": 1, "layer": 1, "time": 0.5, "flat": True, "depth": None}),
    (T("cadcraft", "command_line"), {"text": "line 0,0 10,10"}),
    (T("cadcraft", "save"), {"path": inside("cadcraft", "out", "a.dxf")}),
    (T("figcraft", "create_node"), {"type": "frame", "name": "../not-a-path", "x": 0, "y": 0}),
    (T("filmcraft", "render_preview"), {"seconds": 1.5}),
    (T("filmcraft", "ui_click"), {"x": 1, "y": 2}),
    (T("photocraft", "doc_new"), {"width": 100, "height": 100, "name": "/x"}),
    (T("soundcraft", "inspect_session"), {"detail": "full"}),
    (T("wordcraft", "open_document"), {"path": "https://example.com/a/../b.docx"}),
    (T("wordcraft", "execute"), {"command": "x", "params": {"n": 5, "ok": True, "none": None, "list": [1, 2.5, None]}}),
    (T("pdfcraft", "doc_split"), {"doc": 1, "out_dir": inside("pdfcraft", "out")}),
    (T("designcraft", "execute"), {"command": "hyperlink.create", "params": {"page": 2}}),
    (T("cadcraft", "command_line"), {"text": "line 0,0 attachment-free 1,1"}),
    # --- not a Craft MCP tool at all
    ("mcp__github__create_issue", {"title": "x", "path": "/etc/passwd"}),
    ("mcp__plugin_demo_wordcraft__save_document", {}),
    ("mcp__wordcraft2__save_document", {}),
    ("mcp__wordcraft_save_document", {}),
    ("Bash", {"command": "wordcraft-cli x"}),
    ("mcp__wordcraft__", {}),
]

MALFORMED = [
    "not json",
    "",
    "[]",
    "null",
    "{}",
    '"mcp__wordcraft__save_document"',
    "[1,2",
    '{"tool_name": "mcp__wordcraft__save_document"}',
    '{"tool_name": "mcp__wordcraft__save_document", "tool_input": null}',
    '{"tool_name": "mcp__wordcraft__save_document", "tool_input": []}',
    '{"tool_name": "mcp__wordcraft__save_document", "tool_input": "x"}',
    '{"tool_name": 5, "tool_input": {}}',
    '{"tool_name": null, "tool_input": {"path": "/etc"}}',
    '{"tool_name": ["mcp__wordcraft__save_document"], "tool_input": {}}',
    '{"tool_input": {"path": "/etc/passwd"}}',
]


def run_hook(stdin, hook=HOOK, args=None, env=None):
    if isinstance(stdin, str):
        stdin = stdin.encode("utf-8")
    cmd = [sys.executable, hook] + (args if args is not None else ["--workspace", WS])
    p = subprocess.run(cmd, input=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env or ENV)
    return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")


def call(name, tool_input, **kw):
    return run_hook(json.dumps({"tool_name": name, "tool_input": tool_input, "hook_event_name": "PreToolUse"}), **kw)


CACHE = {}


def key(name, args):
    return name + "\n" + json.dumps(args, sort_keys=True)


def decision(name, args):
    k = key(name, args)
    if k not in CACHE:
        CACHE[k] = call(name, args)
    return CACHE[k]


def prefetch(cases):
    from concurrent.futures import ThreadPoolExecutor
    todo = [(c[0], c[1]) for c in cases if key(c[0], c[1]) not in CACHE]
    with ThreadPoolExecutor(max_workers=4) as pool:
        for (n, a), res in zip(todo, pool.map(lambda c: call(c[0], c[1]), todo)):
            CACHE[key(n, a)] = res


class McpGuardTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        prefetch(ASK + SILENT)

    def test_ask_cases(self):
        for name, args, needle in ASK:
            with self.subTest(tool=name, args=args):
                rc, out, err = decision(name, args)
                self.assertEqual(rc, 0, err)
                self.assertTrue(out.strip(), "expected an ask")
                body = json.loads(out)["hookSpecificOutput"]
                self.assertEqual(body["hookEventName"], "PreToolUse")
                self.assertEqual(body["permissionDecision"], "ask")
                self.assertTrue(body["permissionDecisionReason"].startswith("Craft guard:"))
                self.assertIn(needle.lower(), body["permissionDecisionReason"].lower())

    def test_silent_cases(self):
        for name, args in SILENT:
            with self.subTest(tool=name, args=args):
                rc, out, err = decision(name, args)
                self.assertEqual(rc, 0, err)
                self.assertEqual(out.strip(), "", "expected silence, got %s" % out)

    def test_malformed_input_fails_open(self):
        for raw in MALFORMED:
            with self.subTest(raw=raw):
                rc, out, err = run_hook(raw)
                self.assertEqual(rc, 0)
                self.assertEqual(out.strip(), "")

    def test_binary_input_fails_open(self):
        for raw in (b"\xff\xfe\x00junk", b"\x00" * 500,
                    b'{"tool_name": "mcp__wordcraft__open_document", "tool_input": {"path": "\xff/etc"}}'):
            with self.subTest(raw=raw[:16]):
                rc, out, err = run_hook(raw)
                self.assertEqual((rc, out.strip()), (0, ""))

    def test_never_denies(self):
        for name, args, _ in ASK:
            rc, out, err = decision(name, args)
            self.assertNotIn("deny", json.dumps(json.loads(out)).lower())

    def test_reason_names_the_tool_and_the_fence(self):
        rc, out, _ = decision(T("pdfcraft", "doc_print"), {"doc": 1})
        reason = json.loads(out)["hookSpecificOutput"]["permissionDecisionReason"]
        self.assertIn("doc_print", reason)
        self.assertIn(WS + "/pdfcraft", reason)

    def test_workspace_argument_forms(self):
        args = {"path": "/srv/ws/wordcraft/in/a.docx"}
        name = T("wordcraft", "open_document")
        self.assertTrue(call(name, args)[1].strip())
        self.assertEqual(call(name, args, args=["--workspace", "/srv/ws"])[1].strip(), "")
        self.assertEqual(call(name, args, args=["--workspace=/srv/ws"])[1].strip(), "")
        self.assertEqual(call(name, args, args=["--workspace", "/srv/ws/"])[1].strip(), "")
        self.assertTrue(call(name, args, args=["--workspace", "/srv/other"])[1].strip())
        default = {"path": HOME + "/craft-workspace/wordcraft/in/a.docx"}
        self.assertEqual(call(name, default, args=[])[1].strip(), "")

    def test_each_app_is_fenced_to_its_own_folder_only(self):
        for app in APPS:
            for other in APPS:
                with self.subTest(app=app, other=other):
                    out = call(T(app, "open_file"), {"path": inside(other, "in", "a.bin")})[1].strip()
                    self.assertEqual(bool(out), app != other)

    def test_workspace_given_through_a_symlink(self):
        with tempfile.TemporaryDirectory() as tmp:
            real = os.path.join(tmp, "real", "ws")
            os.makedirs(real)
            link = os.path.join(tmp, "link")
            os.symlink(real, link)
            name = T("gridcraft", "open_workbook")
            for ws, path in ((link, os.path.join(real, "gridcraft", "a.xlsx")),
                             (real, os.path.join(link, "gridcraft", "a.xlsx"))):
                with self.subTest(ws=ws):
                    self.assertEqual(call(name, {"path": path}, args=["--workspace", ws])[1].strip(), "")

    def test_many_path_arguments_are_summarised(self):
        rc, out, _ = call(T("lightcraft", "import"), {"paths": ["/a/%d" % i for i in range(30)]})
        reason = json.loads(out)["hookSpecificOutput"]["permissionDecisionReason"]
        self.assertIn("more path arguments", reason)
        self.assertLess(len(reason), 1500)

    def test_huge_and_deep_arguments_stay_fast_and_fail_open(self):
        deep = cur = {}
        for _ in range(500):
            cur["x"] = {}
            cur = cur["x"]
        # Over a cap the guard must ask (it cannot judge what it did not read), never stay silent
        # (R1-INJECT-5, R1-HOOK-7, B1-INJECT-3).
        over = [
            {"values": [["x%d" % i] * 20 for i in range(2000)]},
            deep,
            {"steps": [{"id": "file.print"}] + [{"id": "frame.create"}] * 25000},
            {"paths": ["/etc/passwd"] + [inside("wordcraft", "in", "%d" % i) for i in range(600)]},
        ]
        for args in over:
            with self.subTest(size=len(json.dumps(args))):
                rc, out, err = call(T("wordcraft", "execute"), args)
                self.assertEqual(rc, 0, err)
                self.assertTrue(out.strip(), "expected an ask over the cap")
                body = json.loads(out)["hookSpecificOutput"]
                self.assertEqual(body["permissionDecision"], "ask")
        rc, out, _ = call(T("filmcraft", "media_import"), {"paths": ["/etc/passwd"] + [inside("filmcraft", "in", "%d" % i) for i in range(600)]})
        self.assertIn("is not under", out)
        rc, out, _ = call(T("designcraft", "batch"), {"commands": [{"command": "file.print"}] + [{"command": "frame.create"}] * 25000})
        self.assertIn("print", out)
        nested = cur = {}
        for _ in range(21):
            cur["x"] = {}
            cur = cur["x"]
        cur["path"] = "/etc/hosts"
        self.assertTrue(call(T("wordcraft", "open_document"), nested)[1].strip())
        for args in ({"text": "a" * 2000000}, {"path": "/" + "a" * 100000}):
            with self.subTest(size=len(json.dumps(args))):
                rc, out, err = call(T("wordcraft", "execute"), args)
                self.assertEqual(rc, 0, err)
                if out.strip():
                    self.assertEqual(json.loads(out)["hookSpecificOutput"]["permissionDecision"], "ask")


class ExistingTargetTests(unittest.TestCase):
    """A save or export onto a file that exists asks (R1-SKILLS-1); a folder target does not."""

    def test_existing_file_asks_and_new_name_is_quiet(self):
        with tempfile.TemporaryDirectory() as tmp:
            ws = os.path.realpath(tmp)
            out = os.path.join(ws, "wordcraft", "out")
            os.makedirs(out)
            old = os.path.join(out, "report-20261014-1200.docx")
            open(old, "w").close()
            args = ["--workspace", ws]
            name = T("wordcraft", "save_document")
            self.assertIn("already exists", call(name, {"path": old}, args=args)[1])
            self.assertEqual(call(name, {"path": os.path.join(out, "report-20261014-1201.docx")}, args=args)[1].strip(), "")
            os.makedirs(os.path.join(ws, "lightcraft", "out"))
            self.assertEqual(call(T("lightcraft", "export"), {"ids": [1], "dir": os.path.join(ws, "lightcraft", "out")},
                                  args=args)[1].strip(), "")


class ReasonTextTests(unittest.TestCase):
    """Long paths keep their end in the reason, so the prompt names the file (B1-SKILLS-2)."""

    def test_long_path_keeps_the_file_name(self):
        with tempfile.TemporaryDirectory() as tmp:
            ws = os.path.join(os.path.realpath(tmp), "a-very-long-folder-name-" * 4)
            out = os.path.join(ws, "wordcraft", "out")
            os.makedirs(out)
            old = os.path.join(out, "quarterly-report-20261014-1200.docx")
            open(old, "w").close()
            reason = call(T("wordcraft", "save_document"), {"path": old}, args=["--workspace", ws])[1]
            self.assertIn("quarterly-report-20261014-1200.docx", reason)
            reason = call(T("wordcraft", "open_document"), {"path": "/elsewhere/" + "x" * 120 + "/secret-plan.docx"})[1]
            self.assertIn("secret-plan.docx", reason)


class TableRobustnessTests(unittest.TestCase):
    def copy_hook(self, table_text):
        tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp, True)
        dest = os.path.join(tmp, "craft-mcp-guard.py")
        shutil.copy(HOOK, dest)
        if table_text is not None:
            with open(os.path.join(tmp, "risky-tools.json"), "w") as f:
                f.write(table_text)
        return dest

    def test_missing_or_broken_table_still_runs_the_path_check(self):
        for label, text in (("missing", None), ("garbage", "{not json"), ("empty", ""), ("list", "[]"),
                            ("wrong shape", '{"apps": 5, "global": []}')):
            hook = self.copy_hook(text)
            with self.subTest(table=label):
                rc, out, _ = call(T("pdfcraft", "doc_print"), {"doc": 1}, hook=hook)
                self.assertEqual((rc, out.strip()), (0, ""))
                rc, out, _ = call(T("wordcraft", "open_document"), {"path": "/etc/passwd"}, hook=hook)
                self.assertEqual(rc, 0)
                self.assertIn("is not under", out)


class TableContentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with open(TABLE, encoding="utf-8") as f:
            cls.table = json.load(f)

    def test_schema_and_apps(self):
        self.assertEqual(self.table["schema"], 1)
        self.assertEqual(sorted(self.table["apps"]), sorted(APPS))

    def test_every_app_entry_is_well_formed(self):
        for app, spec in self.table["apps"].items():
            with self.subTest(app=app):
                self.assertIsInstance(spec["runners"], list)
                for name, why in spec["ask"].items():
                    self.assertTrue(name and isinstance(why, str) and why)
                for name, rule in spec["save"].items():
                    self.assertTrue(rule["any_of"] and rule["why"])
                for rule in spec["args"]:
                    self.assertTrue(rule["arg"] and rule["why"])
                    self.assertTrue(any(k in rule for k in ("equals", "truthy", "present")))

    def test_versions_match_the_lock_when_present(self):
        lock_path = os.path.join(ROOT, "manifest", "apps.lock.json")
        if not os.path.exists(lock_path):
            self.skipTest("no lock file")
        with open(lock_path) as f:
            lock = json.load(f)
        for app, ver in self.table["captured"]["versions"].items():
            with self.subTest(app=app):
                self.assertEqual(ver, lock["apps"][app]["version"],
                                 "risky-tools.json was captured from a different version: re-review it")

    def test_tool_names_and_params_exist_in_the_snapshots_when_present(self):
        """data/tools/<app>.json (from mcp_probe snapshot) is the reviewed list of live tools: a rename or
        a removed parameter in a new app version must show up here, not silently weaken the guard."""
        checked = 0
        for app, spec in self.table["apps"].items():
            snap = os.path.join(ROOT, "data", "tools", "%s.json" % app)
            if not os.path.exists(snap):
                continue
            with open(snap) as f:
                data = json.load(f)
            tools = dict((t["name"], set(t.get("params") or [])) for t in data["tools"])
            for name, params in list(tools.items()):
                if name.startswith("cmd_"):
                    tools.setdefault(name[4:], params)
            # Dotted save rows of runner-only apps (filmcraft file.saveAs) are command ids, not tools.
            names = list(spec["ask"]) + [n for n in spec["save"] if app == "lightcraft" or "." not in n] + list(spec["runners"])
            for name in names:
                with self.subTest(app=app, tool=name):
                    checked += 1
                    self.assertIn(name.replace(".", "_"), tools)
            for name, rule in spec["save"].items():
                params = tools.get(name.replace(".", "_"), set())
                if params:
                    with self.subTest(app=app, save=name):
                        self.assertTrue(set(rule["any_of"]) & params, "none of %s in %s" % (rule["any_of"], sorted(params)))
            for rule in spec["args"]:
                if rule.get("nested"):
                    continue
                for name in rule.get("tools", []):
                    params = tools.get(name.replace(".", "_"), set())
                    if params:
                        with self.subTest(app=app, arg=rule["arg"], tool=name):
                            self.assertIn(rule["arg"], params)
        if not checked:
            self.skipTest("no data/tools snapshots yet")


def load_guard():
    import importlib.util
    spec = importlib.util.spec_from_file_location("craft_mcp_guard_under_test", HOOK)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class TableDrivenTests(unittest.TestCase):
    """Every row of hooks/risky-tools.json must actually fire (a typo in the table would otherwise make a
    row dead), and each save row must go quiet when an explicit in-folder path is given."""

    @classmethod
    def setUpClass(cls):
        os.environ["HOME"] = HOME
        cls.guard = load_guard()
        cls.table = cls.guard.load_table()

    def reasons(self, app, tool, args):
        return self.guard.evaluate(app, tool, args, WS, self.table)[0]

    @staticmethod
    def tool_name(name):
        return ("cmd_" + name.replace(".", "_")) if "." in name else name

    def test_every_ask_row_fires_as_a_tool_and_as_a_command_id(self):
        for app, spec in self.table["apps"].items():
            runner = spec["runners"][0]
            for name in spec["ask"]:
                with self.subTest(app=app, row=name):
                    if "." not in name:
                        self.assertTrue(self.reasons(app, name, {}), "as a tool")
                    elif app == "lightcraft":
                        self.assertTrue(self.reasons(app, self.tool_name(name), {}), "as a cmd_ tool")
                    self.assertTrue(self.reasons(app, runner, {"id": name, "params": {}}), "as a command id")
                    self.assertTrue(self.reasons(app, spec["runners"][-1], {"steps": [{"id": "x"}, {"command": name}]}),
                                    "inside a batch")

    def test_every_ask_id_fires_through_a_runner_and_is_named_by_the_skill(self):
        """ask_ids cannot be checked against data/tools (they are command ids, not tools), so each must be
        named in the app's own skill, whose Never list was written from the live command list."""
        for app, spec in self.table["apps"].items():
            ids = spec.get("ask_ids") or {}
            if not ids:
                continue
            with open(os.path.join(ROOT, "skills", "craft-%s" % app, "SKILL.md"), encoding="utf-8") as f:
                skill = f.read().lower()
            for name in ids:
                with self.subTest(app=app, id=name):
                    self.assertTrue(self.reasons(app, spec["runners"][0], {"id": name, "command": name}))
                    self.assertIn(name.lower(), skill, "name it in the skill's Never list, or drop it")

    def test_every_save_row_asks_without_a_path_and_is_quiet_with_one(self):
        for app, spec in self.table["apps"].items():
            for name, rule in spec["save"].items():
                with self.subTest(app=app, row=name):
                    tool = self.tool_name(name) if "." in name else name
                    self.assertTrue(self.reasons(app, tool, {"doc": 1}))
                    self.assertTrue(self.reasons(app, tool, {rule["any_of"][0]: ""}))
                    for param in rule["any_of"]:
                        good = {param: "%s/%s/out/x.bin" % (WS, app)}
                        self.assertEqual(self.reasons(app, tool, good), [], param)

    def test_every_argument_rule_fires_on_the_risky_value_only(self):
        for app, spec in self.table["apps"].items():
            for rule in spec["args"]:
                with self.subTest(app=app, rule=rule["arg"]):
                    tool = (rule.get("tools") or [spec["runners"][0]])[0]
                    tool = self.tool_name(tool) if "." in tool and app == "lightcraft" else tool
                    if "equals" in rule:
                        risky, calm = rule["equals"], "calm"
                    elif rule.get("truthy"):
                        risky, calm = True, False
                    else:
                        risky, calm = "x", None
                    base = {"path": "%s/%s/out/x.bin" % (WS, app)}
                    hit = self.reasons(app, tool, dict(base, **{rule["arg"]: risky}))
                    self.assertTrue([r for r in hit if rule["why"] in r], hit)
                    quiet = self.reasons(app, tool, dict(base, **{rule["arg"]: calm}))
                    self.assertFalse([r for r in quiet if rule["why"] in r], quiet)

    def test_every_global_rule_fires(self):
        glob = self.table["global"]
        for rule in glob["ask_args"]:
            with self.subTest(arg=rule["arg"]):
                risky = rule["equals"] if "equals" in rule else True
                self.assertTrue(self.reasons("wordcraft", "execute", {"params": {rule["arg"]: risky}}))
        for pat in glob["ask_command_patterns"]:
            with self.subTest(pattern=pat["pattern"]):
                import re
                probes = {"permanent": "x.deletePermanently", "emptytrash|emptyrecentlydeleted|emptybin": "library.emptyTrash",
                          "^(file|doc|document|page)?print(onecopy|score)?$": "file.printOneCopy",
                          "openurl|openlink|linkopen|openexternal|editexternal|openinbrowser|openwith": "link.open",
                          "runscript|evalscript|executescript|scriptrun|jsrun|runjs": "tools.runScript",
                          "addtophotos": "x.addToPhotos",
                          "models?(download|install)|download(models?|placenames|mask)": "x.models.download",
                          "^(doc|document|file|review)?(un)?(protect|encrypt)(sheet|workbook)?$": "review.protectSheet",
                          "publishtoserver|sendtosibelius|exportsibelius|downloadvoices|voiceover": "tts.downloadVoices"}
                self.assertIn(pat["pattern"], probes, "add a probe command id for the new pattern to this test")
                probe = probes[pat["pattern"]]
                self.assertTrue(re.search(pat["pattern"], self.guard.norm(probe)), probe)
                self.assertTrue(self.reasons("gridcraft", "execute_command", {"command": probe}), probe)


class CaseCountTests(unittest.TestCase):
    def test_enough_cases(self):
        self.assertGreaterEqual(len(ASK) + len(SILENT) + len(MALFORMED), 40)
        self.assertGreaterEqual(len(MALFORMED), 5)


if __name__ == "__main__":
    unittest.main(verbosity=1)
