#!/bin/bash



progName=$(basename "$BASH_SOURCE")


trainFilePattern="*train*.conllu"
testFilePattern="*test*.conllu"

iso639File="iso639-codes.txt"

testing="yep"
force=""
iso639mapping=""
splitDevFile=""

generatePatternsString=""
patternsFile=""

optsAdvancedTraining=""

delayed=""

function usage {
  echo
  echo "Usage: $progName [options] <input directory> <output directory>"
  echo
  echo "  Trains multiple tokenizers using pre-tokenized data in .conllu format. This"
  echo "  script is intended to be used with the Universal Dependencies 2.x corpus."
  echo
  echo "  It is assumed that <input directory> contains one directory by dataset, and"
  echo "  that every such directory contains a file which matches '$trainFilePattern',"
  echo "  as well as a file which matches '$testFilePattern'; the former is used for"
  echo "  training an Elephant model, then the model is applied to the latter, used as"
  echo "  test data. Additionally, a baseline tokenizer is applied to the test data"
  echo "  and evaluation is performed for both the trained and the baseline tokenizer."
  echo "  By default an optimal Wapiti pattern is obtained by using cross-validation"
  echo "  for a set of patterns generated automatically (see options -g and -i)."
  echo
  echo "  Options:"
  echo "    -h this help"
  echo "    -t training only; by default the tokenizer model is also applied to the"
  echo "       test dataset."
  echo "    -g <parameters for generating patterns> parameter string which specifies"
  echo "       which patterns are generated; transmitted as option -s when calling"
  echo "       script generate-patterns.pl; call this script with -h for more details."
  echo "    -i <list of patterns file> use this specific list of pattern files instead"
  echo "       of generating the list automatically."
  echo "    -m <max no progress> specify the max number of patterns with no progress for"
  echo "       stopping the process; 0 means process all files."
  echo "    -k <K> value for k-fold cross-validation."
  echo "    -p <train file pattern> pattern to use for finding the train file;"
  echo "       default: '$trainFilePattern'"
  echo "    -P <test file pattern> pattern to use for finding the test file;"
  echo "       default: '$testFilePattern'"
  echo "    -e use Elman language models (usually performs better but longer training)"
  echo "    -f force overwriting any previously existing tokenizers in"
  echo "       <output directory>; by default existing models are not recomputed."
  echo "    -l generate language codes mapping file; this assumes that the input .conllu"
  echo "       filenames start with the ISO639 language codes (intended for UD2 corpus)."
  echo "    -n <parameters model name> name to use for the parameters model directory;"
  echo "       this is useful when runnning this script several times with different"
  echo "       parameters."
  echo "    -s <training set proportion> Split test file into training and test set if "
  echo "       no training file is found (this is a workaround for the two languages in"
  echo "       UD2 for which only a dev file is supplied: UD_Kazakh and UD_Uyghur)."
  echo "       Example: -s 0.8 means 80% train set, 20% test set."
  echo "    -b do not apply script to fix missing B labels in testing: applied by"
  echo "       default, but should not be applied if tokens can include whitespaces."
  echo "       Ignored if -t is supplied."
  echo "    -d delay processing: instead of calling the script advanced-training.sh,"
  echo "       the command is printed to STDOUT for every dataset. This allows"
  echo "       dsitributed processing later."
  echo 
}




OPTIND=1
while getopts 'htg:i:m:k:p:P:efln:s:bd' option ; do 
    case $option in
	"h" ) usage
 	      exit 0;;
	"t" ) testing="";;
	"g" ) generatePatternsString="$OPTARG";;
	"i" ) patternsFile="$OPTARG";;
	"m" ) optsAdvancedTraining="$optsAdvancedTraining -m \"$OPTARG\"";;
	"k" ) optsAdvancedTraining="$optsAdvancedTraining -k \"$OPTARG\"";;
	"p" ) trainFilePattern="$OPTARG";;
	"P" ) testFilePattern="$OPTARG";;
	"e" ) optsAdvancedTraining="$optsAdvancedTraining -e";;
	"f" ) force="yep";;
	"l" ) iso639mapping="yep";;
	"n" ) optsAdvancedTraining="$optsAdvancedTraining -n \"$OPTARG\"";;
	"s" ) splitDevFile="$OPTARG";;
	"b" ) optsAdvancedTraining="$optsAdvancedTraining -b";;
	"d" ) optsAdvancedTraining="$optsAdvancedTraining -q"
	      delayed="yes";;
 	"?" ) 
	    echo "Error, unknow option." 1>&2
            printHelp=1;;
    esac
done
shift $(($OPTIND - 1))
if [ $# -ne 2 ]; then
    echo "Error: expecting 2 args." 1>&2
    printHelp=1
fi

if [ ! -z "$printHelp" ]; then
    usage 1>&2
    exit 1
fi
inputDir="$1"
outputDir="$2"

if [ ! -z "$force" ]; then
    rm -rf $outputDir
fi
[ -d "$outputDir" ] || mkdir "$outputDir"

if [ -z "$patternsFile" ]; then
    patternsFile="$outputDir/patterns.list"
    rm -rf "$outputDir/patterns"
    mkdir "$outputDir/patterns"
    opts=""
    if [ ! -z "$generatePatternsString" ]; then
	opts="-s \"$generatePatternsString\""
    fi
    echo "* Generating patterns to '$patternsFile';" 1>&2
    comm="generate-patterns.pl $opts \"$outputDir/patterns/\" >\"$patternsFile\""
    eval "$comm"
    if [ $? -ne 0 ]; then
	echo "An error occured when running '$comm', aborting" 1>&2
	exit 54
    fi
fi


for dataDir in "$inputDir"/*; do
    if [ -d "$dataDir" ]; then
	testingThis="$testing"
	data=$(basename "$dataDir")
	lsPatTrain="$dataDir/$trainFilePattern"
	trainFile=$(ls $lsPatTrain 2>/dev/null | head -n 1)
	lsPatTest="$dataDir/$testFilePattern"
	testFile=$(ls $lsPatTest 2>/dev/null | head -n 1)
	if [ -z "$trainFile" ] && [ -z "$testFile" ]; then
	    echo "Warning: no file matches '$lsPatTrain' neither '$lsPatTest', ignoring dataset '$data'." 1>&2
	else
	    opts="$optsAdvancedTraining"
	    if [ -z "$testFile" ]; then
		echo "Warning: no file matches '$lsPatTest', skipping testing for '$data'." 1>&2
	    else
		opts="$opts -t \"$testFile\""
	    fi
	    
	    # from here we have either a train set or a test set
	    if [ -z "$trainFile" ] && [ -z "$splitDevFile" ]; then
		echo "Warning: no file matches '$lsPatTrain' for training and no option -s, ignoring dataset '$data'." 1>&2
	    else
		# from here we have a train set or a test + split option (or both)
		if [ -z "$trainFile" ]; then # no train set: we split the test set
		    echo "Warning: no file matches '$lsPatTrain' in '$data'; splitting test file '$testFile'." 1>&2
		    prefixSplit=$(mktemp --tmpdir "$progName.split-dev-file.XXXXXXXXXX")
		    split-conllu-sentences.pl -b "$prefixSplit." -p "$splitDevFile" "$testFile"
		    trainFile="$prefixSplit.1"
		    testFile="$prefixSplit.2"
		    opts="$opts -r \"$cleanupFiles $prefixSplit.1 $prefixSplit.2\""
		fi
		# now we have a train set, but it's still possible we don't have a test set; we're doing the training anyway
		command="advanced-training.sh $opts \"$trainFile\" \"$patternsFile\" \"$outputDir/$data\""

		if [ -z "$delayed" ]; then
		    eval "$command"
		else
		    echo "$command"
		fi
		
	    fi
	fi
    fi
done
if [ ! -z "$iso639mapping" ]; then
    echo "### Generating ISO639 codes mapping..." 1>&2
    generate-iso639-codes-file.sh "$inputDir" >"$outputDir/$iso639File"
fi
