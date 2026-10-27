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
LEX_INC  := -I$(LEX)/include -I$(LEX)/lexlib
APP_INC  := $(SCI_INC) $(LEX_INC) -I$(NPP)/src/pugixml -Isrc

# --- Scintilla (core + Cocoa platform layer) -------------------------------
SCI_SRC  := $(wildcard $(SCI)/src/*.cxx)
SCI_MM   := $(SCI)/cocoa/PlatCocoa.mm $(SCI)/cocoa/ScintillaCocoa.mm \
            $(SCI)/cocoa/ScintillaView.mm $(SCI)/cocoa/InfoBar.mm
SCI_OBJ  := $(patsubst $(SCI)/%,$(OBJ)/sci/%.o,$(SCI_SRC) $(SCI_MM))

# --- Lexilla (all lexers, including Notepad++'s user/searchResult) --------
LEX_SRC  := $(wildcard $(LEX)/lexlib/*.cxx) $(wildcard $(LEX)/lexers/*.cxx) $(LEX)/src/Lexilla.cxx
LEX_OBJ  := $(patsubst $(LEX)/%,$(OBJ)/lex/%.o,$(LEX_SRC))

# --- The app ---------------------------------------------------------------
APP_SRC  := $(wildcard src/*.mm) $(wildcard src/*.cpp)
APP_OBJ  := $(patsubst src/%,$(OBJ)/app/%.o,$(APP_SRC))
APP_HDR  := $(wildcard src/*.h)

LIBSCI   := $(BUILD)/libscintilla.a
LIBLEX   := $(BUILD)/liblexilla.a
EXE      := $(APP)/Contents/MacOS/Notepad++
RES      := $(APP)/Contents/Resources

FRAMEWORKS := -framework Cocoa -framework QuartzCore -framework UniformTypeIdentifiers

.PHONY: all run install clean
all: $(EXE) resources sign

$(OBJ)/sci/%.cxx.o: $(SCI)/%.cxx
	@mkdir -p $(dir $@)
	@echo "  CXX   scintilla/$*.cxx"
	@clang++ -std=c++17 $(CXXFLAGS) $(SCI_INC) -c $< -o $@

$(OBJ)/sci/%.mm.o: $(SCI)/%.mm
	@mkdir -p $(dir $@)
	@echo "  OBJC  scintilla/$*.mm"
	@clang++ -std=c++17 $(CXXFLAGS) $(OBJCFLAGS) $(SCI_INC) -c $< -o $@

$(OBJ)/lex/%.cxx.o: $(LEX)/%.cxx
	@mkdir -p $(dir $@)
	@echo "  CXX   lexilla/$*.cxx"
	@clang++ -std=c++17 $(CXXFLAGS) -Icompat $(SCI_INC) $(LEX_INC) -c $< -o $@

$(OBJ)/app/%.mm.o: src/%.mm $(APP_HDR)
	@mkdir -p $(dir $@)
	@echo "  OBJC  macos/src/$*.mm"
	@clang++ $(CXXSTD) $(CXXFLAGS) $(OBJCFLAGS) -Wall $(APP_INC) -c $< -o $@

$(OBJ)/app/%.cpp.o: src/%.cpp $(APP_HDR)
	@mkdir -p $(dir $@)
	@echo "  CXX   macos/src/$*.cpp"
	@clang++ $(CXXSTD) $(CXXFLAGS) -Wall $(APP_INC) -c $< -o $@

$(LIBSCI): $(SCI_OBJ)
	@rm -f $@ && libtool -static -o $@ $^ 2>/dev/null

$(LIBLEX): $(LEX_OBJ)
	@rm -f $@ && libtool -static -o $@ $^ 2>/dev/null

$(EXE): $(APP_OBJ) $(LIBSCI) $(LIBLEX)
	@mkdir -p $(dir $@)
	@echo "  LINK  Notepad++"
	@clang++ $(ARCHS) $(MINOS) -fobjc-arc $(APP_OBJ) $(LIBSCI) $(LIBLEX) $(FRAMEWORKS) -o $@

# Upstream data files are copied verbatim, so the port picks up upstream
# language/theme/localization updates on every merge from master.
.PHONY: resources sign
resources: $(EXE)
	@mkdir -p $(RES)/themes $(RES)/localization
	@cp Info.plist $(APP)/Contents/Info.plist
	@cp $(NPP)/src/langs.model.xml $(RES)/langs.model.xml
	@cp $(NPP)/src/stylers.model.xml $(RES)/stylers.model.xml
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
