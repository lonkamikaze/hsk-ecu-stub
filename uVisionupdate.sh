#!/bin/sh
set -f

IFS='
'

# Must not be set or GNU make produces problematic output on stdout
unset MAKELEVEL
eval "$(make printEnv)"
project="$PROJECT"
PROJECT="$(echo "$project" | tr '[:lower:]' '[:upper:]')"

echo "Generating C-headers from DBCs ..." 1>&2
make dbc

# Get required .c files from the libraries.
echo "Getting .c files to include ..." 1>&2
libs="$(find src/ -name *.c \
	     -exec $AWK -f $LIBPROJDIR/scripts/depends.awk .c -link \
	                -I$INCDIR/ -I$LIBDIR/ -I$GENDIR/ -DSDCC {} + \
	| grep "^${LIBDIR%/}/" | sort -u)"
echo "$libs" | sed 's/^/	/' 1>&2

echo "Preparing header include directories ..." 1>&2
_LIBDIR="$(echo "$LIBDIR" | tr '/' '\\')"
_GENDIR="$(echo "$GENDIR" | tr '/' '\\')"
_SIMDIR="$(echo "$LIBPROJDIR/uVision/simulator.ini" | tr '/' '\\')"

# Create groups
echo "Creating library groups ..." 1>&2

groupname() {
	local name
	name="${1%/*}"
	name="${name##*/}"
	echo "$name" | tr '[[:lower:]]' '[[:upper:]]' | sed 's/_/::/'
}

oldGroupname=
for lib in $libs; do
	test ! -f "$lib" && continue
	groupname="$(groupname "$lib")"
	# Open new group
	if [ "$oldGroupname" != "$groupname" ]; then
		echo "	Create group: $groupname" 1>&2
		oldGroupname="$groupname"
		hasOptions=
		libdeps="$libdeps
			-insert:Group
			-selectInserted
			-insert:GroupName=$groupname
			-select:.."
	fi
	if [ -z "$hasOptions" ]; then
		if grep -Eq '^[[:space:]]*#[[:space:]]*pragma[[:space:]](.*[[:space:]])?asm($|[[:space:]].*)' "$lib"; then
			echo "	Activate assembly: $groupname" 1>&2
			hasOptions=1
			libdeps="$libdeps
				-search:Group/GroupName=$groupname/..
				-insert:GroupOption
				-selectInserted
				-insert:CommonProperty
				-selectInserted
				-insert:UseCPPCompiler=0
				-insert:RVCTCodeConst=0
				-insert:RVCTZI=0
				-insert:RVCTOtherData=0
				-insert:ModuleSelection=0
				-insert:IncludeInBuild=2
				-insert:AlwaysBuild=2
				-insert:GenerateAssemblyFile=1
				-insert:AssembleAssemblyFile=1
				-insert:PublicsOnly=2
				-insert:StopOnExitCode=11
				-insert:CustomArgument
				-insert:IncludeLibraryModules
				-insert:BankNo=65535
				-select:..
				-insert:Group51
				-selectInserted
				-insert:C51
				-selectInserted
				-insert:RegisterColoring=2
				-insert:VariablesInOrder=2
				-insert:IntegerPromotion=2
				-insert:uAregs=2
				-insert:UseInterruptVector=2
				-insert:Fuzzy=8
				-insert:Optimize=10
				-insert:WarningLevel=3
				-insert:SizeSpeed=2
				-insert:ObjectExtend=2
				-insert:ACallAJmp=2
				-insert:InterruptVectorAddress=0
				-insert:VariousControls
				-selectInserted
				-insert:MiscControls
				-insert:Define
				-insert:Undefine
				-insert:IncludePath
				-select:../..
				-insert:Ax51
				-selectInserted
				-insert:UseMpl=2
				-insert:UseStandard=2
				-insert:UseCase=2
				-insert:UseMod51=2
				-insert:VariousControls
				-selectInserted
				-insert:MiscControls
				-insert:Define
				-insert:Undefine
				-insert:IncludePath
				-select:../../../../.."
		fi
	fi
done

echo "Adding files ..." 1>&2
libdeps="$libdeps
	-search:Group/GroupName=*::*/..
	-insert:Files
	-select:/
	-search:Group/GroupName=*::BOOT/../Files
	-insert:File
	-selectInserted
	-insert:FileName=startup.a51
	-insert:FileType=2
	-insert:FilePath=..\\$_LIBDIR\\hsk_boot\\startup.a51"

for lib in $libs; do
	test ! -f "$lib" && continue
	incfiles="$incfiles${IFS}$lib"
	groupname="$(groupname "$lib")"
	filename="${lib##*/}"
	filepath="$(echo "$lib" | tr '/' '\\')"
	echo "	Add file: $groupname/$filename" 1>&2
	libdeps="$libdeps
		-select:/
		-search:Group/GroupName=$groupname/../Files
		-insert:File
		-selectInserted
		-insert:FileName=$filename
		-insert:FileType=1
		-insert:FilePath=..\\$filepath"
done

echo "Getting call tree changes for overlay optimisation ..." 1>&2
overlays="$($AWK -f ${LIBPROJDIR}/scripts/overlays.awk $incfiles $(find src/ -name \*.c) -I$INCDIR -I$LIBDIR -I$GENDIR)"
echo "$overlays" | sed -e 's/^/	/' -e 's/[[:cntrl:]]$//' 1>&2

echo "Updating uVision/hsk-ecu.uvopt ..." 1>&2
# This is a bug workaround see ARM case 531308
if cp uVision/hsk-ecu.uvopt uVision/hsk-ecu.uvopt.bak 2> /dev/null; then
	$AWK -f ${LIBPROJDIR}/scripts/xml.awk uVision/hsk-ecu.uvopt.bak \
		-search:DebugOpt/sIfile \
		-set:"..\\$_SIMDIR" \
		-select:/ \
		-print > uVision/hsk-ecu.uvopt \
			&& rm uVision/hsk-ecu.uvopt.bak \
			|| mv uVision/hsk-ecu.uvopt.bak uVision/hsk-ecu.uvopt
fi

echo "Updating uVision/hsk-ecu.uvproj ..." 1>&2
cp uVision/hsk-ecu.uvproj uVision/hsk-ecu.uvproj.bak
$AWK -f ${LIBPROJDIR}/scripts/xml.awk uVision/hsk-ecu.uvproj.bak \
	-search:TargetName \
	-set:"$PROJECT" \
	-select:/ \
	-search:OutputName \
	-set:"$project" \
	-select:/ \
	-search:Target51/C51/VariousControls/IncludePath \
	-set:"..\\$_LIBDIR;..\\$_GENDIR" \
	-select:/ \
	-search:OverlayString \
	-set:"$overlays" \
	-select:/ \
	-search:SimDlls/InitializationFile \
	-set:"..\\$_SIMDIR" \
	-select:/ \
	-search:"Group/GroupName=HSK_LIBS/.." \
	-delete \
	-select:/ \
	-search:"Group/GroupName=HSK_LIBS::*/.." \
	-delete \
	-select:/ \
	-search:"Group/GroupName=*::*/.." \
	-delete \
	-select:/ \
	-search:"Groups" \
	$libdeps \
	-select:/ \
	-print > uVision/hsk-ecu.uvproj \
		&& rm uVision/hsk-ecu.uvproj.bak \
		|| mv uVision/hsk-ecu.uvproj.bak uVision/hsk-ecu.uvproj

