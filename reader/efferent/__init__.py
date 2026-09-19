"""The reading side of Efferent.

Everything here runs next to the reading key, on the owner's machine, and it
has to: opening a day means decrypting it, and the key never leaves. The wire —
keys, HPKE, the day layout, edits — is ``efferent_hpke``, the same file an agent
receives from the remote ``setup_guide``; this package is what sits on top of it
for the owner: the mirror, the questions, the command line and the MCP server.
"""
