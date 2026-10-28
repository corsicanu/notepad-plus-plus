// Reads and writes Notepad++'s own config.xml and session.xml formats in
// ~/Library/Application Support/Notepad++ (the %APPDATA%\Notepad++ of
// Windows). Only the values the port understands are touched; every other
// element of an existing config.xml is kept, so files can move between
// Windows and macOS installations.
#pragma once

#include <string>
#include <vector>

struct SessionFileInfo
{
	std::string fileName;          // full path, or "new 1" for untitled
	std::string backupFilePath;    // snapshot of unsaved changes
	std::string langName;          // Notepad++ language short name ("C++")
	int encoding = -1;
	long firstVisibleLine = 0;
	long xOffset = 0;
	long startPos = 0;
	long endPos = 0;
	bool userReadOnly = false;
	bool untitleTabRenamed = false;
	int tabColour = -1;
	bool tabPinned = false;
	long long originalFileLastModifTimestamp = 0;
	std::vector<long> marks;
	std::vector<long> folds;
};

struct Session
{
	int activeView = 0;
	int activeMainIndex = 0;
	int activeSubIndex = 0;
	std::vector<SessionFileInfo> mainViewFiles;
	std::vector<SessionFileInfo> subViewFiles;
};

class NppConfig
{
public:
	static NppConfig& instance();

	// ~/Library/Application Support/Notepad++
	const std::string& userDir() const { return _dir; }
	std::string backupDir() const { return _dir + "/backup"; }

	void load();
	void save();

	// Recent file list (<History>).
	std::vector<std::string> recentFiles;
	int nbMaxRecentFiles = 10;

	// Window position (<GUIConfig name="AppPosition">).
	int appX = 0, appY = 0, appW = 1100, appH = 760;
	bool appMaximized = false;
	bool appPositionValid = false;

	// Docking panels (<GUIConfig name="DockingManager">): PluginDlg entries,
	// internal panels under "Notepad++::InternalFunction", plugins kept as read.
	struct DockPanelInfo { std::string name; int id = 0; int curr = 0; int prev = -1; bool visible = false; };
	int dockLeftWidth = 200, dockRightWidth = 200, dockTopHeight = 200, dockBottomHeight = 200;
	std::vector<DockPanelInfo> dockPanels;
	std::vector<std::pair<int, int>> dockActiveTabs;   // (cont, activeTab)

	// Folder as Workspace (<FileBrowser latestSelectedItem=""><root foldername=""/>).
	std::vector<std::string> fileBrowserRoots;
	std::string fileBrowserSelectedItem;

	// HMAC of shortcuts.xml approved by the user (<GUIConfig name="shortcutsXmlHMAC">).
	std::string shortcutsXmlHmac;

	static bool loadSession(const std::string& path, Session& session);
	static bool saveSession(const std::string& path, const Session& session);
	std::string sessionPath() const { return _dir + "/session.xml"; }

private:
	NppConfig();
	std::string _dir;
};
