#!/usr/bin/python3
"""Set the test screen colour from the compositor's actual Return-key receipt."""
from pathlib import Path
import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk

window = Gtk.Window()
window.set_name("desklink-test-screen")
style = Gtk.CssProvider()
style.load_from_data(b"#desklink-test-screen { background-color: #1f59a5; }"
                     b"#desklink-test-screen.received { background-color: #34ae92; }")
window.get_style_context().add_provider(style, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

def check_input():
    if Path("/var/lib/desklink-test/results/green").exists():
        window.get_style_context().add_class("received")
    else:
        window.get_style_context().remove_class("received")
    return True

window.fullscreen()
window.show_all()
GLib.timeout_add(100, check_input)
Gtk.main()
