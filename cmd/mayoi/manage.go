package main

import (
	"github.com/egoist/mygo/ui"
)

// The Manage button, as VS Code's gear at the bottom left: a menu of the
// command palette, the settings, the keyboard shortcuts, the theme and
// the terminal's default shell. It sits at the foot of the rail of
// project tabs, or, without the rail, at the left of the status bar.

// manageMenu fills the Manage button's menu.
func (a *app) manageMenu(m *ui.Menu) {
	if m.Item(a.withKey("Command Palette…", "go.commands")).Chosen() {
		a.post(func() { a.openQuick(">") })
	}
	m.Separator()
	if m.Item(a.withKey("Settings", "file.settings")).Chosen() {
		a.post(a.openSettings)
	}
	if m.Item("Keyboard Shortcuts").Chosen() {
		a.post(a.openKeybindings)
	}
	m.Separator()
	m.Submenu("Theme", func(m *ui.Menu) {
		for _, th := range []struct{ id, label string }{
			{"", appName}, {themeMatrix, "The Matrix"}, {themeClaude, "Claude"}, {themeQoder, "Qoder"},
		} {
			if m.Item(th.label).Checked(a.settings.Theme == th.id).Chosen() {
				a.post(func() { a.setTheme(th.id) })
			}
		}
		m.Separator()
		for _, ap := range []struct{ id, label string }{{"", "System"}, {"light", "Light"}, {"dark", "Dark"}} {
			if m.Item(ap.label).Checked(a.settings.Appearance == ap.id).Disabled(a.settings.Theme == themeMatrix).Chosen() {
				a.post(func() { a.setAppearance(ap.id) })
			}
		}
	})
	m.Submenu("File Icon Theme", func(m *ui.Menu) {
		for _, th := range []struct{ id, label string }{{"", "Material"}, {iconThemeLucide, "Lucide"}} {
			if m.Item(th.label).Checked(a.settings.IconTheme == th.id).Chosen() {
				a.post(func() { a.setIconTheme(th.id) })
			}
		}
	})
	m.Submenu("Default Terminal Profile", func(m *ui.Menu) {
		def := a.defaultProfile().name
		for _, p := range a.termProfiles() {
			if m.Item(p.name).Checked(p.name == def).Chosen() {
				a.post(func() { a.setDefaultProfile(p.name) })
			}
		}
	})
	m.Separator()
	if m.Item("Project Tabs").Checked(a.settings.ProjectTabs).Chosen() {
		a.post(a.toggleProjectTabs)
	}
	if m.Item("Auto Save").Checked(a.settings.AutoSave).Chosen() {
		a.post(a.toggleAutoSave)
	}
}

// manageButton is the gear that opens the Manage menu, w wide.
func (a *app) manageButton(c *ui.Context, w, h float32) {
	p := a.pal
	b := ui.ButtonBase(c.Key("manage")).Size(w, h).Shrink(0).Justify(ui.Center).AlignItems(ui.Center).
		Label("Manage").Tooltip("Manage")
	col := p.muted
	if b.Hovered() || b.Pressed() {
		col = p.text
	}
	b.Children(func() { ui.Icon(c, iconGear).FontSize(20).TextColor(col) })
	b.Menu(a.manageMenu)
}

// railShown reports whether the rail of project tabs shows, which then
// has the Manage button.
func (a *app) railShown() bool { return a.rail != nil && a.settings.ProjectTabs }
