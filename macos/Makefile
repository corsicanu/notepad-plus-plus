# Notepad++ for macOS - build with Command Line Tools only (no Xcode needed).
#   make            build Notepad++.app into $(BUILD)
#   make run        build and launch
#   make install    copy the app to ~/Applications
#   make clean
#
# Builds outside the source tree: codesign rejects bundles under ~/Desktop
# because of Finder extended attributes.

ROOT     := $(abspath ..)
BUILD    ?= $(HOME)/Library/Caches/NotepadPP-build
APP      := $(BUILD)/Notepad++.app
OBJ      := $(BUILD)/obj

SCI      := $(ROOT)/scintilla
LEX      := $(ROOT)/lexilla
NPP      := $(ROOT)/PowerEditor

ARCHS    ?= -arch arm64 -arch x86_64
MINOS    := -mmacosx-version-min=11.0
OPT      ?= -O2
CXXSTD   := -std=c++20
CXXFLAGS := $(OPT) $(ARCHS) $(MINOS) -DNDEBUG -Wno-deprecated-declarations
OBJCFLAGS := -fobjc-arc

SCI_INC  := -I$(SCI)/include -I$(SCI)/src -I$(SCI)/cocoa
# Notepad++ replaces Scintilla's regex engine with boost::regex (boostregex/nppSpecifics.mak).
SCI_DEFS := -DSCI_OWNREGEX -DBOOST_REGEX_STANDALONE -I$(ROOT)/boostregex
LEX_INC  := -I$(LEX)/include -I$(LEX)/lexlib
GEN      := $(BUILD)/gen
APP_INC  := $(SCI_INC) $(LEX_INC) -I$(NPP)/src/pugixml -Isrc -Icompat -I$(GEN) \
            -I$(NPP)/src -I$(NPP)/src/MISC/Common -I$(NPP)/src/MISC/PluginsManager \
            -I$(NPP)/src/ScintillaComponent -I$(NPP)/src/WinControls/FindCharsInRange -I$(NPP)/src/uchardet \
            -I$(NPP)/src/WinControls/ColourPicker -I$(NPP)/src/WinControls/Preference -I$(NPP)/src/WinControls/shortcut \
            -I$(NPP)/src/WinControls/Grid

# --- Scintilla (core + Cocoa platform layer) -------------------------------
SCI_SRC  := $(wildcard $(SCI)/src/*.cxx)
SCI_MM   := $(SCI)/cocoa/PlatCocoa.mm $(SCI)/cocoa/ScintillaCocoa.mm \
            $(SCI)/cocoa/ScintillaView.mm $(SCI)/cocoa/InfoBar.mm
SCI_OBJ  := $(patsubst $(SCI)/%,$(OBJ)/sci/%.o,$(SCI_SRC) $(SCI_MM)) \
            $(OBJ)/boostregex/BoostRegExSearch.cxx.o $(OBJ)/boostregex/UTF8DocumentIterator.cxx.o

# --- Lexilla (all lexers, including Notepad++'s user/searchResult) --------
LEX_SRC  := $(wildcard $(LEX)/lexlib/*.cxx) $(wildcard $(LEX)/lexers/*.cxx) $(LEX)/src/Lexilla.cxx
LEX_OBJ  := $(patsubst $(LEX)/%,$(OBJ)/lex/%.o,$(LEX_SRC))

# --- Portable upstream PowerEditor sources, compiled unchanged ------------
NPPLIB_SRC := $(wildcard $(NPP)/src/uchardet/*.cpp) $(NPP)/src/EncodingMapper.cpp
NPPLIB_OBJ := $(patsubst $(NPP)/src/%,$(OBJ)/npp/%.o,$(NPPLIB_SRC))

# --- The app ---------------------------------------------------------------
APP_SRC  := $(wildcard src/*.mm) $(wildcard src/*.cpp)
APP_OBJ  := $(patsubst src/%,$(OBJ)/app/%.o,$(APP_SRC))
APP_HDR  := $(wildcard src/*.h)

LIBSCI   := $(BUILD)/libscintilla.a
LIBLEX   := $(BUILD)/liblexilla.a
LIBNPP   := $(BUILD)/libnppcore.a
EXE      := $(APP)/Contents/MacOS/Notepad++
RES      := $(APP)/Contents/Resources

FRAMEWORKS := -framework Cocoa -framework QuartzCore -framework UniformTypeIdentifiers

.PHONY: all run install clean
all: $(EXE) resources sign

$(OBJ)/sci/%.cxx.o: $(SCI)/%.cxx
	@mkdir -p $(dir $@)
	@echo "  CXX   scintilla/$*.cxx"
	@clang++ -std=c++17 $(CXXFLAGS) $(SCI_INC) $(SCI_DEFS) -c $< -o $@

$(OBJ)/boostregex/%.cxx.o: $(ROOT)/boostregex/%.cxx
	@mkdir -p $(dir $@)
	@echo "  CXX   boostregex/$*.cxx"
	@clang++ -std=c++17 $(CXXFLAGS) $(SCI_INC) $(SCI_DEFS) -w -c $< -o $@

$(OBJ)/sci/%.mm.o: $(SCI)/%.mm
	@mkdir -p $(dir $@)
	@echo "  OBJC  scintilla/$*.mm"
	@clang++ -std=c++17 $(CXXFLAGS) $(OBJCFLAGS) $(SCI_INC) $(SCI_DEFS) -c $< -o $@

$(OBJ)/lex/%.cxx.o: $(LEX)/%.cxx
	@mkdir -p $(dir $@)
	@echo "  CXX   lexilla/$*.cxx"
	@clang++ -std=c++17 $(CXXFLAGS) -Icompat $(SCI_INC) $(LEX_INC) -c $< -o $@

# Tables lifted from upstream sources (see tools/gen_upstream.sh).
GEN_INC  := $(GEN)/MenuIds.inc $(GEN)/WinKeyDefs.inc $(GEN)/ScintKeyDefs.inc $(GEN)/MenuID2LangType.inc \
            $(GEN)/ToolbarIcons.inc $(GEN)/TabContextMenu.inc $(GEN)/PrefPages.inc $(GEN)/MenuFolderPositions.inc
$(GEN_INC): $(GEN)/.stamp
$(GEN)/.stamp: tools/gen_upstream.sh $(NPP)/src/Notepad_plus.rc $(NPP)/src/Parameters.cpp $(NPP)/src/Notepad_plus.cpp $(NPP)/src/NppNotification.cpp \
             $(NPP)/src/WinControls/Preference/preferenceDlg.cpp $(NPP)/src/localization.cpp
	@echo "  GEN   upstream tables"
	@sh tools/gen_upstream.sh $(NPP)/src $(GEN)
	@touch $@

$(OBJ)/npp/%.cpp.o: $(NPP)/src/%.cpp
	@mkdir -p $(dir $@)
	@echo "  CXX   PowerEditor/src/$*.cpp"
	@clang++ -std=c++17 $(CXXFLAGS) -w -Icompat -include compat/windows.h -I$(NPP)/src -I$(NPP)/src/uchardet $(SCI_INC) -c $< -o $@

$(OBJ)/app/%.mm.o: src/%.mm $(APP_HDR) $(GEN_INC)
	@mkdir -p $(dir $@)
	@echo "  OBJC  macos/src/$*.mm"
	@clang++ $(CXXSTD) $(CXXFLAGS) $(OBJCFLAGS) -Wall $(APP_INC) -c $< -o $@

$(OBJ)/app/%.cpp.o: src/%.cpp $(APP_HDR) $(GEN_INC)
	@mkdir -p $(dir $@)
	@echo "  CXX   macos/src/$*.cpp"
	@clang++ $(CXXSTD) $(CXXFLAGS) -Wall $(APP_INC) -c $< -o $@

$(LIBSCI): $(SCI_OBJ)
	@rm -f $@ && libtool -static -o $@ $^ 2>/dev/null

$(LIBLEX): $(LEX_OBJ)
	@rm -f $@ && libtool -static -o $@ $^ 2>/dev/null

$(LIBNPP): $(NPPLIB_OBJ)
	@rm -f $@ && libtool -static -o $@ $^ 2>/dev/null

$(EXE): $(APP_OBJ) $(LIBSCI) $(LIBLEX) $(LIBNPP)
	@mkdir -p $(dir $@)
	@echo "  LINK  Notepad++"
	@clang++ $(ARCHS) $(MINOS) -fobjc-arc $(APP_OBJ) $(LIBSCI) $(LIBLEX) $(LIBNPP) $(FRAMEWORKS) -o $@

# Upstream data files are copied verbatim, so the port picks up upstream
# language/theme/localization updates on every merge from master.
.PHONY: resources sign
resources: $(EXE)
	@mkdir -p $(RES)/themes $(RES)/localization
	@cp Info.plist $(APP)/Contents/Info.plist
	@cp $(NPP)/src/langs.model.xml $(RES)/langs.model.xml
	@cp $(NPP)/src/stylers.model.xml $(RES)/stylers.model.xml
	@cp $(NPP)/src/Notepad_plus.rc $(RES)/Notepad_plus.rc
	@rsync -a --delete $(NPP)/src/icons/ $(RES)/icons/
	@mkdir -p $(RES)/rc
	@find $(NPP)/src \( -name '*.rc' -o -name '*_rc.h' -o -name '*Res.h' -o -name '*Resource.h' -o -name '*resource.h' -o -name resource.h -o -name menuCmdID.h \) -exec cp {} $(RES)/rc/ \;
	@cp $(NPP)/installer/themes/*.xml $(RES)/themes/ 2>/dev/null || true
	@cp $(NPP)/installer/nativeLang/*.xml $(RES)/localization/ 2>/dev/null || true
	@for n in info_bar_bg mac_cursor_busy mac_cursor_flipped; do \
		[ -f $(RES)/$$n.tiff ] || tiffutil -cathidpicheck $(SCI)/cocoa/res/$$n.png $(SCI)/cocoa/res/$$n@2x.png -out $(RES)/$$n.tiff >/dev/null 2>&1; \
	done

sign: resources
	@codesign --force --sign - $(APP) 2>/dev/null && echo "  SIGN  $(APP)"

run: all
	@open $(APP)

install: all
	@rm -rf $(HOME)/Applications/Notepad++.app
	@mkdir -p $(HOME)/Applications
	@cp -R $(APP) $(HOME)/Applications/
	@echo "Installed to ~/Applications/Notepad++.app"

clean:
	rm -rf $(BUILD)
