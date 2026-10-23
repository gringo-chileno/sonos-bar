"""Makes an iPhone Shortcut that toggles play/pause on one Sonos room.

Usage: python3 make.py "Evie music" 192.168.68.52
Writes "<name>.shortcut" (signed, ready to open on an iPhone) next to this script.
"""
import os, plistlib, subprocess, sys, tempfile, uuid

AV = "urn:schemas-upnp-org:service:AVTransport:1"


def soap(action, args=""):
    return (f'<?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
            f's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:{action} xmlns:u="{AV}">'
            f'<InstanceID>0</InstanceID>{args}</u:{action}></s:Body></s:Envelope>')


def text(s):
    return {"Value": {"string": s, "attachmentsByRange": {}}, "WFSerializationType": "WFTextTokenString"}


def output_of(uid, name):
    return {"Value": {"OutputUUID": uid, "Type": "ActionOutput", "OutputName": name}, "WFSerializationType": "WFTextTokenAttachment"}


def call(url, action, args=""):
    """A Text action holding the SOAP body, then a POST that sends it. Returns (actions, uuid of the POST)."""
    body_id, post_id = str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper()
    headers = [("Content-Type", 'text/xml; charset="utf-8"'), ("SOAPACTION", f'"{AV}#{action}"')]
    return [
        {"WFWorkflowActionIdentifier": "is.workflow.actions.gettext",
         "WFWorkflowActionParameters": {"UUID": body_id, "WFTextActionText": soap(action, args)}},
        {"WFWorkflowActionIdentifier": "is.workflow.actions.downloadurl",
         "WFWorkflowActionParameters": {
             "UUID": post_id, "WFURL": url, "WFHTTPMethod": "POST", "ShowHeaders": True,
             "WFHTTPHeaders": {"Value": {"WFDictionaryFieldValueItems": [
                 {"WFItemType": 0, "WFKey": text(k), "WFValue": text(v)} for k, v in headers]},
                 "WFSerializationType": "WFDictionaryFieldValue"},
             "WFHTTPBodyType": "File",
             "WFRequestVariable": output_of(body_id, "Text"),
         }},
    ], post_id


def main(name, ip):
    url = f"http://{ip}:1400/MediaRenderer/AVTransport/Control"
    group = str(uuid.uuid4()).upper()
    check, state_id = call(url, "GetTransportInfo")
    pause, _ = call(url, "Pause")
    play, _ = call(url, "Play", "<Speed>1</Speed>")

    def branch(mode, extra=None):
        params = {"GroupingIdentifier": group, "WFControlFlowMode": mode}
        params.update(extra or {})
        return {"WFWorkflowActionIdentifier": "is.workflow.actions.conditional", "WFWorkflowActionParameters": params}

    actions = check + [
        # Playing → pause, anything else → play.
        branch(0, {"WFCondition": 99, "WFConditionalActionString": ">PLAYING<",
                   "WFInput": {"Type": "Variable", "Variable": output_of(state_id, "Contents of URL")}}),
        *pause,
        branch(1),
        *play,
        branch(2),
    ]
    shortcut = {
        "WFWorkflowActions": actions,
        "WFWorkflowClientVersion": "2607.0.2",
        "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowMinimumClientVersionString": "900",
        "WFWorkflowIcon": {"WFWorkflowIconStartColor": 4282601983, "WFWorkflowIconGlyphNumber": 61440},
        "WFWorkflowImportQuestions": [],
        "WFWorkflowInputContentItemClasses": [],
        "WFWorkflowOutputContentItemClasses": [],
        "WFWorkflowTypes": [],
        "WFWorkflowHasShortcutInputVariables": False,
    }
    here = os.path.dirname(os.path.abspath(__file__))
    with tempfile.NamedTemporaryFile(suffix=".shortcut", delete=False) as f:
        plistlib.dump(shortcut, f, fmt=plistlib.FMT_BINARY)
    out = os.path.join(here, f"{name}.shortcut")
    subprocess.run(["shortcuts", "sign", "--mode", "anyone", "--input", f.name, "--output", out], check=True)
    os.unlink(f.name)
    print(out)


if __name__ == "__main__":
    main(*sys.argv[1:3])
