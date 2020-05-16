#/usr/bin/perl -w

use strict;
use warnings;

package RenderApp::Controller::RenderProblem;

BEGIN {
	use File::Basename;
	$main::dirname = dirname(__FILE__);
	# Unused variable, but define it twice to avoid an error message.
	$WeBWorK::Constants::WEBWORK_DIRECTORY = $main::dirname."/../../WeBWorK";
	$WeBWorK::Constants::PG_DIRECTORY      = $main::dirname."/../../PG";
	#unless (-r $WeBWorK::Constants::WEBWORK_DIRECTORY ) {
#		die "Cannot read webwork root directory at $WeBWorK::Constants::WEBWORK_DIRECTORY";
	#}
	unless (-r $WeBWorK::Constants::PG_DIRECTORY ) {
		die "Cannot read webwork pg directory at $WeBWorK::Constants::PG_DIRECTORY";
	}
}

#######################################################
# Find the webwork2 root directory
#######################################################

use Carp;
#use Crypt::SSLeay;  # needed for https
#use LWP::Protocol::https;
use Time::HiRes qw/time/;
use MIME::Base64 qw(encode_base64 decode_base64);
use Getopt::Long qw[:config no_ignore_case bundling];
use File::Find;
use FileHandle;
use File::Path;
#use File::Temp qw/tempdir/;
use String::ShellQuote;
use Cwd 'abs_path';

use lib "$WeBWorK::Constants::WEBWORK_DIRECTORY/lib";
use lib "$WeBWorK::Constants::PG_DIRECTORY/lib";

use Proc::ProcessTable; # use in standalonePGproblemRenderer
use WeBWorK::PG; #webwork2 (use to set up environment)
use WeBWorK::CourseEnvironment;
use RenderApp::Controller::FormatRenderedProblem;

use 5.10.0;
$Carp::Verbose = 1;

### verbose output when UNIT_TESTS_ON =1;
our $UNIT_TESTS_ON = 0;

#our @path_list;

##################################################
# create log files :: expendable
##################################################

my $path_to_log_file = 'logs/standalone_results.log';

eval { # attempt to create log file
	local(*FH);
	open(FH, '>>:encoding(UTF-8)',$path_to_log_file) or die "Can't open file $path_to_log_file for writing";
	close(FH);
};

die "You must first create an output file at $path_to_log_file with permissions 777 " unless -w $path_to_log_file;

##########################################################
#  END MAIN :: BEGIN SUBROUTINES
##########################################################

#######################################################################
# Process the pg file
#######################################################################

sub process_pg_file {
	my $inputHash = shift;
	my $NO_ERRORS = "";
	my $ALL_CORRECT = "";

	our $seed_ce = create_course_environment();

	my $file_path = $inputHash->{filePath};

	# just make sure we have the fundamentals covered...
	my $form_data = {
		displayMode			=> 'MathJax',
		outputformat		=> $inputHash->{outputFormat}||'simple',
		problem_seed		=> $inputHash->{problemSeed}||'666',
		problemSeed			=> $inputHash->{problemSeed}||'123',
		language				=> $inputHash->{language}||'en',
		form_action_url => $inputHash->{form_action_url}||'http://failure.org'
		#psvn            => $psvn//'23456',
		#forcePortNumber => $credentials{forcePortNumber}//'',
	};
	# pull the inputs_ref up a level into the form_data hash
	$form_data = {%{$inputHash->{inputs_ref}}, %{$form_data}};

	my $pg_start = time; # this is Time::HiRes's time, which gives floating point values

	my ($error_flag, $formatter, $error_string) =
	    process_problem($seed_ce, $file_path, $form_data);

	my $pg_stop = time;
	my $pg_duration = $pg_stop-$pg_start;

	# extract and display result
	# print "display $file_path\n";
	return display_html_output($file_path, $formatter);

}

#######################################################################
# Process Problem
#######################################################################

sub process_problem {
	my $ce 				 = shift;
	my $file_path  = shift;
	my $inputs_ref = shift;

	### get source and correct file_path name so that it is relative to templates directory
	### revisit: DO WE NEED TO ADJUST THE FILE PATH???
	my ($adj_file_path, $source) = get_source($file_path);
	#print "find file at $adj_file_path ", length($source), "\n";

	### update inputs
	my $problem_seed = $inputs_ref->{problem_seed};
	die "problem seed not defined in sendXMLRPC::process_problem" unless $problem_seed;

#  my $local_psvn = $form_data->{psvn}//34567;
# formerly updated_input -- now inputs_ref
# removed ->{envir}{...}
	#$inputs_ref->{fileName} = $adj_file_path;
	#$inputs_ref->{probFileName} = $adj_file_path;
	$inputs_ref->{sourceFilePath} = $adj_file_path;
	#$inputs_ref->{pathToProblemFile} = $adj_file_path;
	$inputs_ref->{problemSeed} = $problem_seed;

# These can FORCE display of AnsGroup AnsHash PGInfo and ResourceInfo
#	$inputs_ref->{showAnsGroupInfo}	= 1; #$print_answer_group;
#	$inputs_ref->{showAnsHashInfo}		= 1; #$print_answer_hash;
#	$inputs_ref->{showPGInfo}				= 1; #$print_pg_hash;
#	$inputs_ref->{showResourceInfo}	= 1; #$print_resource_hash;

	##################################################
	# Process the pg file
	##################################################
	### store the time before we invoke the content generator
	my $cg_start = time; # this is Time::HiRes's time, which gives floating point values

	############################################
	# Call server via standaloneRenderer to render problem
	############################################

	our($return_object, $error_flag, $error_string);
	$error_flag=0; $error_string='';

	my $memory_use_start = get_current_process_memory();
  # can include @args as fourth input below
	$return_object = standaloneRenderer($ce, \$source, $inputs_ref);

	#######################################################################
	# Handle errors
	#######################################################################

	print "\n\n Result of renderProblem \n\n" if $UNIT_TESTS_ON;
	print pretty_print_rh($return_object) if $UNIT_TESTS_ON;
	if (not defined $return_object) {  #FIXME make sure this is the right error message if site is unavailable
		$error_string = "0\t Could not process $file_path problem file \n";
	} elsif (defined($return_object->{flags}->{error_flag}) and $return_object->{flags}->{error_flag} ) {
		$error_string = "0\t $file_path has errors\n";
	} elsif (defined($return_object->{errors}) and $return_object->{errors} ){
		$error_string = "0\t $file_path has syntax errors\n";
	}
	$error_flag=1 if $return_object->{errors};

	##################################################
	# Create FormatRenderedProblems object
	##################################################

	#my $encoded_source = encode_base64($source); # create encoding of source_file;
	my $formatter = RenderApp::Controller::FormatRenderedProblem->new(
		return_object    => $return_object,
		encoded_source   => encode_base64($source),
		sourceFilePath   => $file_path,
		url              => $inputs_ref->{form_action_url},   # use default hosted2
		form_action_url  => $inputs_ref->{form_action_url},
		maketext         =>  sub {return @_},
		courseID         =>  'blackbox',
		userID           =>  'Motoko_Kusanagi',
		course_password  =>  'daemon',
		inputs_ref       =>  $inputs_ref,
	);

	##################################################
	# log elapsed time
	##################################################
	my $scriptName = 'standalonePGproblemRenderer';
	my $cg_end = time;
	my $cg_duration = $cg_end - $cg_start;
	my $memory_use_end = get_current_process_memory();
	my $memory_use = $memory_use_end - $memory_use_start;
	writeRenderLogEntry("",
		"{script:$scriptName; file:$file_path; ".
		 sprintf("duration: %.3f sec;", $cg_duration).
		 sprintf(" memory: %6d bytes;", $memory_use).   "}",'');

	#######################################################################
	# End processing of the pg file
	#######################################################################

	return $error_flag, $formatter, $error_string;
}

###########################################
# standalonePGproblemRenderer
###########################################

sub standaloneRenderer {
	#print "entering standaloneRenderer\n\n";
	my $ce					= shift;
  my $problemFile = shift//'';
  my $form_data   = shift//'';
  my %args = @_;

	# my $key = $r->param('key');
	# WTF is this even here for? PG doesn't do authz
	my $key = '3211234567654321';

	my $user          = fake_user();
	my $set           = fake_set();
	my $showHints     = $form_data->{showHints} || 0;
	my $showSolutions = $form_data->{showSolutions} || 0;
	my $problemNumber = $form_data->{'problem_number'} || 1;
  my $displayMode   = $form_data->{displayMode} || $ce->{pg}->{options}->{displayMode};
	my $problem_seed  = $form_data->{'problem_seed'} || 0; #$r->param('problem_seed') || 0;

	my $translationOptions = {
		displayMode     	=> $displayMode,
		showHints       	=> $showHints,
		showSolutions   	=> $showSolutions,
		refreshMath2img 	=> 1,
		processAnswers  	=> 1,
		QUIZ_PREFIX     	=> '',
		use_site_prefix 	=> 'localhost:5000',
		use_opaque_prefix => 0,
		permissionLevel 	=> 20
	};
	my $extras = {};   # Check what this is used for - passed as arg to renderer->new()

	$form_data->{displayMode} = $displayMode;

	# Create template of problem then add source text or a path to the source file
	local $ce->{pg}{specialPGEnvironmentVars}{problemPreamble} = {TeX=>'',HTML=>''};
	local $ce->{pg}{specialPGEnvironmentVars}{problemPostamble} = {TeX=>'',HTML=>''};
	my $problem = fake_problem(); # eliminated $db arg
	$problem->{problem_seed} = $problem_seed;
	$problem->{value} = -1;
	if (ref $problemFile) { #in this case the actual source is passed
			$problem->{source_file} = $form_data->{sourceFilePath};
			$translationOptions->{r_source} = $problemFile;
			# warn "standaloneProblemRenderer: setting source_file = $problemFile";
			# print "source is already read\n";
			# a text string containing the problem
	} else {
			$problem->{source_file} = $problemFile;
			warn "standaloneProblemRenderer: setting source_file = $problemFile";
			# a path to the problem (relative to the course template directory?)
	}

	#FIXME temporary hack
	#$set->set_id('this set') unless $set->set_id();
	#$problem->problem_id('1') unless $problem->problem_id();

	my $pg = WeBWorK::PG->new(
		$ce,
		$user,
		$key,
		$set,
		$problem,
		123, # PSVN (practically unused in PG)  only used as an identifier
		$form_data,
		$translationOptions,
		$extras,
	);
		# new version of output:
	my $warning_messages = '';  # for now -- set up warning trap later
	my ($internal_debug_messages, $pgwarning_messages, $pgdebug_messages);
    if (ref ($pg->{pgcore}) ) {
    	$internal_debug_messages   = $pg ->{pgcore}->get_internal_debug_messages;
    	$pgwarning_messages        = $pg ->{pgcore}->get_warning_messages();
    	$pgdebug_messages          = $pg ->{pgcore}->get_debug_messages();
    } else {
    	$internal_debug_messages = ['Error in obtaining debug messages from PGcore'];
    }

	my $out2 = {
		text												=> $pg->{body_text},
		header_text									=> $pg->{head_text},
		answers											=> $pg->{answers},
		errors											=> $pg->{errors},
		WARNINGS										=> encode_base64(
		                               "WARNINGS\n".$warning_messages."\n<br/>More<br/>\n".$pg->{warnings}
		                               ),
		PG_ANSWERS_HASH             => $pg->{pgcore}->{PG_ANSWERS_HASH},
		problem_result							=> $pg->{result},
		problem_state								=> $pg->{state},
		flags												=> $pg->{flags},
		warning_messages            => $pgwarning_messages,
		debug_messages              => $pgdebug_messages,
		internal_debug_messages     => $internal_debug_messages,
	};
	print"\n pg answers ", join(" ",  %{$pg->{answers}} ) if $UNIT_TESTS_ON;
	$pg->free;
	$out2;
}

# helper function to remove temp dirs
sub delete_temp_dir {
	my ($temp_dir_path) = @_;

	my $rm_cmd = "2>&1 rm -rf " . shell_quote($temp_dir_path);  #can use perl command for this??
	my $rm_out = readpipe $rm_cmd;
	if ($?) {
		print "Failed to remove temporary directory '".$temp_dir_path."':\n$rm_out\n";
		return 0;
	} else {
		return 1;
	}
}

sub create_tex_output {
	my $file_path = shift;
	my $formatter = shift;
	my $output_text = $formatter->formatRenderedProblem;
	$file_path =~s|/$||;   # remove final /
	$file_path =~ m|/?([^/]+)$|;
	my $file_name = $1;
	$file_name =~ s/\.\w+$/\.tex/;    # replace extension with tex
	my $output_file = TEMPOUTPUTDIR().$file_name;
	local(*FH);
	open(FH, '>:encoding(UTF-8)', $output_file) or die "Can't open file $output_file for writing";
	print FH $output_text;
	close(FH);
	print "tex result sent to $output_file\n" if $UNIT_TESTS_ON;
#	sleep 5;   #wait 5 seconds
#	unlink($output_file);
	return $file_name;
}

sub display_tex_output {
	my $file_path = shift;
	my $formatter = shift;
	my $output_text = $formatter->formatRenderedProblem;
	$file_path =~s|/$||;   # remove final /
	$file_path =~ m|/?([^/]+)$|;
	my $file_name = $1;
	$file_name =~ s/\.\w+$/\.tex/;    # replace extension with tex
	my $output_file = TEMPOUTPUTDIR().$file_name;
	local(*FH);
	open(FH, '>', $output_file) or die "Can't open file $output_file for writing";
	print FH $output_text;
	close(FH);
	print "tex result sent to $output_file\n" if $UNIT_TESTS_ON;
#	if ($display_pdf_output) {
		print "pdf mode\n";
		my $pdf_file_name = $file_name;
		$pdf_file_name =~ s/\.\w+$/\.pdf/;    # replace extension with pdf
		my $pdf_path = TEMPOUTPUTDIR().$pdf_file_name;
		print "pdflatex $output_file\n";
		system("pdflatex $output_file");
		print "pdflatex to $pdf_path DONE\n";
		# this is doable but will require changing directories
		# look at the solution done using hardcopy
		system("open -a Preview ". $pdf_path);
#	}
#	sleep 5;   #wait 5 seconds
#	unlink($output_file);
}

sub create_json_output {
	my $file_path = shift;
	my $formatter = shift;
	my $output_text = $formatter->formatRenderedProblem;
	$file_path =~s|/$||;   # remove final /
	$file_path =~ m|/?([^/]+)$|;
	my $file_name = $1;
	$file_name =~ s/\.\w+$/\.json/;    # replace extension with json
	my $output_file = TEMPOUTPUTDIR().$file_name;
	local(*FH);
	open(FH, '>:encoding(UTF-8)', $output_file) or die "Can't open file $output_file for writing";
	print FH $output_text;
	close(FH);
	print "json result sent to $output_file\n" if $UNIT_TESTS_ON;
#	sleep 5;   #wait 5 seconds
#	unlink($output_file);
	return $file_name;
}

sub	display_html_output {  #display the problem in a browser
	my $file_path = shift;
	my $formatter = shift;
	my $output_text = $formatter->formatRenderedProblem;
	return $output_text;
	$file_path =~s|/$||;   # remove final /
	$file_path =~ m|/?([^/]+)$|;
	my $file_name = $1;
	$file_name =~ s/\.\w+$/\.html/;    # replace extension with html
	my $output_file = TEMPOUTPUTDIR().$file_name;
	local(*FH);
	open(FH, '>:encoding(UTF-8)', $output_file) or die "Can't open file $output_file for writing";
	print FH $output_text;
	close(FH);
  #specify  HTML_DISPLAY_COMMAND
	#system($HTML_DISPLAY_COMMAND." ".$output_file);
	sleep 5;   #wait 1 seconds
	unlink($output_file);
}

sub display_hash_output {   # print the entire hash output to the command line
	my $file_path = shift;
	my $formatter = shift;
	my $output_text = $formatter->formatRenderedProblem;
	$file_path =~s|/$||;   # remove final /
	$file_path =~ m|/?([^/]+)$|;
	my $file_name = $1;
	$file_name =~ s/\.\w+$/\.txt/;    # replace extension with html
	my $output_file = TEMPOUTPUTDIR().$file_name;
	my $output_text2 = pretty_print_rh($output_text);
	print STDOUT $output_text2;

# 	local(*FH);
# 	open(FH, '>', $output_file) or die "Can't open file $output_file writing";
# 	print FH $output_text2;
# 	close(FH);
#
# 	system($HASH_DISPLAY_COMMAND().$output_file."; rm $output_file;");
	#sleep 1; #wait 1 seconds
	#unlink($output_file);
}

sub display_ans_output {  # print the collection of answer hashes to the command line
	my $file_path = shift;
	my $formatter = shift;
	my $return_object = $formatter->return_object;
	$file_path =~s|/$||;   # remove final /
	$file_path =~ m|/?([^/]+)$|;
	my $file_name = $1;
	$file_name =~ s/\.\w+$/\.txt/;    # replace extension with html
	my $output_file = TEMPOUTPUTDIR().$file_name;
	my $output_text = pretty_print_rh($return_object->{answers});
	print STDOUT $output_text;
# 	local(*FH);
# 	open(FH, '>', $output_file) or die "Can't open file $output_file writing";
# 	print FH $output_text;
# 	close(FH);
#
# 	system($HASH_DISPLAY_COMMAND().$output_file."; rm $output_file;");
# 	sleep 1; #wait 1 seconds
# 	unlink($output_file);
}

sub record_problem_ok1 {
	my $error_flag = shift//'';
	my $formatter = shift;  # for formatting
	my $file_path = shift;
	my $return_string = '';
	my $return_object = $formatter->return_object;
	if (defined($return_object->{flags}->{DEBUG_messages}) ) {
		my @debug_messages = @{$return_object->{flags}->{DEBUG_messages}};
		$return_string .= (pop @debug_messages ) ||'' ; #avoid error if array was empty
		if (@debug_messages) {
			$return_string .= join(" ", @debug_messages);
		} else {
					$return_string = "";
		}
	}
	if (defined($return_object->{errors}) ) {
		$return_string= $return_object->{errors};
	}
	if (defined($return_object->{flags}->{WARNING_messages}) ) {
		my @warning_messages = @{$return_object->{flags}->{WARNING_messages}};
		$return_string .= (pop @warning_messages)||''; #avoid error if array was empty
			$@=undef;
		if (@warning_messages) {
			$return_string .= join(" ", @warning_messages);
		} else {
			$return_string = "";
		}
	}
	my $SHORT_RETURN_STRING = ($return_string)?"has errors":"ok";
	unless ($return_string) {
		$return_string = "1\t $file_path is ok\n";
	} else {
		$return_string = "0\t $file_path has errors\n";
	}

	local(*FH);
	open(FH, '>>:encoding(UTF-8)',$path_to_log_file) or die "Can't open file $path_to_log_file for writing";
	print FH $return_string;
	close(FH);
	return $SHORT_RETURN_STRING;
}

sub record_problem_ok2 {
	my $error_flag = shift//'';
	my $formatter = shift;
	my $file_path = shift;
	my $some_correct_answers_not_specified = shift;
	my $pg_duration = shift;  #processing time
	my $return_object = $formatter->return_object;
	my %scores = ();
	my $ALL_CORRECT= 0;
	my $all_correct = ($error_flag)?0:1;
		foreach my $ans (keys %{$return_object->{answers}} ) {
			$scores{$ans} =
			      $return_object->{answers}->{$ans}->{score};
			$all_correct =$all_correct && $scores{$ans};
		}
	$all_correct = ".5" if $some_correct_answers_not_specified;
	$ALL_CORRECT = ($all_correct == 1)?'All answers are correct':'Some answers are incorrect';
	local(*FH);
	open(FH, '>>:encoding(UTF-8)',$path_to_log_file) or die "Can't open file $path_to_log_file for writing";
	print FH "$all_correct $file_path\n"; #  do we need this? compile_errors=$error_flag\n";
	close(FH);
	return $ALL_CORRECT;
}

##################################################
# utilities
##################################################

sub get_current_process_memory {
  state $pt = Proc::ProcessTable->new;
  my %info = map { $_->pid => $_ } @{$pt->table};
  return $info{$$}->rss;
}

sub fake_user {
#	my ($db) = @_;
	my $user = {
		user_id => 'Motoko_Kusanagi',
		first_name=>'Motoko',
		last_name=>'Kusanagi',
		email_address=>'motoko.kusanagi@npsc.go.jp',
		student_id=>'',
		section=>'9',
		recitation=>'',
		comment=>'',
	};
	return($user);
}

sub fake_problem {
  #	my $db = shift;
	my $problem = {}; #$db->newGlobalProblem();
	#$problem = global2user($db->{problem_user}->{record}, $problem);

	$problem->{set_id} = "Section_9";
	$problem->{problem_id} = 1;
	$problem->{value} = 1;
	$problem->{max_attempts} = -1;
	$problem->{showMeAnother} = -1;
	$problem->{showMeAnotherCount} = 0;
	$problem->{problem_seed} = 666;
	$problem->{status} = 0;
	$problem->{sub_status} = 0;
	$problem->{attempted} = 2000;  # Large so hints won't be blocked
	$problem->{last_answer} = "";
	$problem->{num_correct} = 1000;
	$problem->{num_incorrect} = 1000;
	$problem->{prCount} = -10; # Negative to detect fake problems and disable problem randomization.

	return($problem);
}

sub fake_set {
  #	my $db = shift;

	my $set = {};
	$set->{psvn} = 666;
	$set->{set_id} = "Section_9";
	$set->{open_date} = time();
	$set->{due_date} = time();
	$set->{answer_date} = time();
	$set->{visible} = 0;
	$set->{enable_reduced_scoring} = 0;
	$set->{hardcopy_header} = "defaultHeader";
	return($set);
}

sub display_inputs {
	my %correct_answers = @_;
	foreach my $key (sort keys %correct_answers) {
		print "$key => $correct_answers{$key}\n";
	}
}

sub edit_source_file {
	my $file_path = shift;
	system(EDIT_COMMAND()." $file_path");
}

# Get problem template source and adjust file_path name
sub get_source {
	my $file_path = shift;
	my $source;
	die "Unable to read file $file_path \n" unless $file_path eq '-' or -r $file_path;
	eval {  #File::Slurp would be faster (see perl monks)
		 local $/=undef;
		if ($file_path eq '-') {
			$source = <STDIN>;
		} else {
			# To support proper behavior with UTF-8 files, we need to open them with "<:encoding(UTF-8)"
			# as otherwise, the first HTML file will render properly, but when "Preview" "Submit answer"
			# or "Show correct answer" is used it will make problems, as in process_problem() the
			# encodeSource() method is called on a data which is still UTF-8 encoded, and leads to double
			# encoding and gibberish.
			# NEW:
			open(FH, "<:encoding(UTF-8)" ,$file_path) or die "Couldn't open file $file_path: $!";
			# OLD:
			#open(FH, "<" ,$file_path) or die "Couldn't open file $file_path: $!";
			$source   = <FH>; #slurp  input
			close FH;
		}
	};
	die "Something is wrong with the contents of $file_path\n" if $@;
	### adjust file_path so that it is relative to the rendering course directory
	#$file_path =~ s|/opt/webwork/libraries/NationalProblemLibrary|Library|;
	#$file_path =~ s|^.*?/webwork-open-problem-library/OpenProblemLibrary|Library|;
	print "file_path changed to $file_path\n" if $UNIT_TESTS_ON;
	print $source  if  $UNIT_TESTS_ON;
	return $file_path, $source;
}

sub pretty_print_rh {
    shift if UNIVERSAL::isa($_[0] => __PACKAGE__);
	my $rh = shift;
	my $indent = shift || 0;
	my $out = "";
	my $type = ref($rh);

	if (defined($type) and $type) {
		$out .= " type = $type; ";
	} elsif (! defined($rh )) {
		$out .= " type = UNDEFINED; ";
	}
	return $out." " unless defined($rh);

	if ( ref($rh) =~/HASH/  ) {
	    $out .= "{\n";
	    $indent++;
 		foreach my $key (sort keys %{$rh})  {
 			$out .= "  "x$indent."$key => " . pretty_print_rh( $rh->{$key}, $indent ) . "\n";
 		}
 		$indent--;
 		$out .= "\n"."  "x$indent."}\n";

 	} elsif (ref($rh)  =~  /ARRAY/ or "$rh" =~/ARRAY/) {
 	    $out .= " ( ";
 		foreach my $elem ( @{$rh} )  {
 		 	$out .= pretty_print_rh($elem, $indent);

 		}
 		$out .=  " ) \n";
	} elsif ( ref($rh) =~ /SCALAR/ ) {
		$out .= "scalar reference ". ${$rh};
	} elsif ( ref($rh) =~/Base64/ ) {
		$out .= "base64 reference " .$$rh;
	} else {
		$out .=  $rh;
	}

	return $out." ";
}

sub create_course_environment {
	my $self = shift;
	my $courseName = $self->{courseName} || 'blackbox';
	my $ce = WeBWorK::CourseEnvironment->new(
				{webwork_dir		=> $WeBWorK::Constants::WEBWORK_DIRECTORY,
				 courseName			=> $courseName
				});
	warn "Unable to find environment for course: |$courseName|" unless ref($ce);
	return ($ce);
}

sub writeRenderLogEntry($$$) {
	my ($function, $details, $beginEnd) = @_;
	$beginEnd = ($beginEnd eq "begin") ? ">" : ($beginEnd eq "end") ? "<" : "-";
	#WeBWorK::Utils::writeLog($seed_ce, "render_timing", "$$ ".time." $beginEnd $function [$details]");
}

1;