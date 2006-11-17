#!/usr/local/bin/perl

=head1  NAME

ngap2legacydb.pl - load NGAP data into the legacy database schema.

=head1 SYNOPSIS

USAGE: ngap2legacydb.pl
        --input_list=/path/to/somefile.bsml.list
        --server=SYBTIGR
        --database=sma1
      [ --log=/path/to/some/log ]

=head1 OPTIONS

B<--input_list,-i>
    BSML list file from an NGAP workflow component run.

B<--server,-s>
    Sybase server name.

B<--database,-d>
    Sybase project database ID.

B<--log,-d>
    optional. Will create a log file with summaries of all actions performed.

B<--debug>
    optional. Will display verbose status messages to STDERR if logging is disabled.
    
B<--help,-h>
    This help message/documentation.

=head1   DESCRIPTION
    
    This script will remove all existing NGAP results from a project database, and load the contents of input BSML files.

=head1 INPUT

    The input should be a list of BSML files generated by the NGAP component of a workflow pipeline.

=head1 OUTPUT

    There is no output unless you use the --log option.

=head1 CONTACT

    Brett Whitty
    bwhitty@tigr.org

=cut

use warnings;
use strict;
use DBI;
use Getopt::Long qw(:config no_ignore_case no_auto_abbrev);
use Pod::Usage;
use lib '/usr/local/devel/ANNOTATION/ard/current/lib/5.8.8';
use BSML::BsmlReader;
use BSML::BsmlParserSerialSearch;

my %options = ();
my $results = GetOptions (\%options,
                          'input_list|i=s',
                          'server|s=s',
                          'database|d=s',
                          'log|l=s',
                          'debug',
                          'help|h',
                         ) || pod2usage();

# display documentation
if( $options{'help'} ){
    pod2usage( {-exitval=>0, -verbose => 2, -output => \*STDOUT} );
}

checkOptions(\%options);

## get the current user
my $user = getpwuid($<);

## open the log if requested
if (defined($options{'log'})) {
    open(LOG, ">".$options{'log'}) || die "can't create log file: $!";
}

unless (-e $options{'input_list'}) {
    log_die("input list '".$options{'input_list'}."' does not exist.");
}

my $parser = new BSML::BsmlParserSerialSearch( SequenceCallBack => \&sequenceHandler,
                                               ReadFeatureTables => 1
                                             );
                                             
my $seq_id = '';
my %ngaps = ();
## used to track database query error state
my $QUERYFAIL = 0;

open (IN, $options{'input_list'}) || log_die("could not open input list '".$options{'input_list'}."' for reading");
my @bsml_files = <IN>;
close IN;

my $dbh = connectToDb($options{'server'},'Sybase','egc','egcpwd',$options{'database'});

foreach my $bsml_file(@bsml_files) {
    chomp $bsml_file;
    unless (-e $bsml_file) {
        log_error("BSML input file '$bsml_file' does not exist");
        next;
    }
    
    $parser->parse($bsml_file) || log_die("failed parsing '$bsml_file'");
    foreach my $asmbl_id(keys(%ngaps)) {
        delete_gene_predictions($dbh, $asmbl_id, "NGAP");
        foreach my $ngap(@{$ngaps{$asmbl_id}}) {
            ## load forward pair
            loadModelPair($dbh, $asmbl_id, $ngap->[0], $ngap->[1]);
            ## load reverse pair
            loadModelPair($dbh, $asmbl_id, $ngap->[1], $ngap->[0]);
        }
    }
}

## Reads NGAP position information from BSML sequence elements
sub sequenceHandler {
    my $sequence = shift;
    $ngaps{$sequence->returnattr('id')} = [];
    my $ftbl_list_arr_ref = $sequence->returnBsmlFeatureTableListR();
    foreach my $ftbl_ref(@{$ftbl_list_arr_ref}) {
        my $feat_list_arr_ref = $ftbl_ref->returnBsmlFeatureListR();
        foreach my $feat_ref(@{$feat_list_arr_ref}) {
                my $iloc_list_arr_ref = $feat_ref->returnBsmlIntervalLocListR();
                foreach my $iloc_ref(@{$iloc_list_arr_ref}) {
                    push(@{$ngaps{$sequence->returnattr('id')}}, [$iloc_ref->{'startpos'}, $iloc_ref->{'endpos'}]);
                }
        }
    }
    return;
}

## This sub was taken from the original NGAP loader script
sub loadModelPair {
    my ($dbproc, $asmbl_id, $coord1, $coord2) = @_;
    my $by = $user;
    log_this("Loading up the model...\n");
    my $model_feat_name = &getNextName ($dbproc, $asmbl_id, "model");
    &insert_asm_feature($dbproc, $model_feat_name, $asmbl_id, "model", $coord1, $coord2, $by, "workflow", 0, 0);
    &insert_phys_ev($dbproc, $model_feat_name, "NGAP", $by);
    log_this("Loading up exon...\n");
    my $exon_feat_name = &getNextName ($dbproc, $asmbl_id, "exon");
    &insert_asm_feature($dbproc, $exon_feat_name, $asmbl_id, "exon", $coord1, $coord2, $by, "workflow", 0,0);
    &insert_phys_ev($dbproc, $exon_feat_name, "NGAP", $by);
    &insert_feat_link($dbproc, $exon_feat_name, $model_feat_name, "egc", "now");
}

## This sub is taken from Egc_library.pm
sub getNextName {
    my($dbproc, $id, $type) = @_;
    my($query, $num, $zerobuf, $zeros, $name, %char);
    
    $char{'exon'}='e';
    $char{'model'}='m';
    $char{'TU'}='t';
    $char{'donor'}='d';
    $char{'acceptor'}='a';
    $char{'CDS'}='c';
    $char{'repeat'}='repeat';
    $char{'misc_feature'} = 'miscf';
    $char{'6fseg'} = '6fseg';
    $char{'trf'} = 'trf';
    $char{'rna-exon'} = 'x';
    if (!exists $char{$type}) {
        $char{$type} = lc $type;
    }

    $num = &getMaxNo($dbproc, $id, $type);
    $num++;
    $zeros= 5 - length($num);
    for (my $i=0; $i<$zeros; $i++){
        $zerobuf .= "0";
    }

    $name = $id . ".".$char{$type}.$zerobuf.$num;
    return($name);
}

## This sub is taken from Egc_library.pm
sub getMaxNo {
    my ($dbproc, $asmbl_id, $feat_type) = @_;
    
    my $num = 0;
    
    my $query = "select a.feat_name "
        . "from asm_feature a "
        . "where a.asmbl_id = $asmbl_id "
        . "and a.feat_type = \'$feat_type\' "
        . "having a.feat_id = max(a.feat_id) ";
    
    my $feat_name = &first_result_sql($dbproc, $query);
    if ($feat_name) {
    $feat_name =~ /\D(\d+)$/ or die "ERROR, feat_name $feat_name lacks required trailing numbers.\n";
    $num = $1;
    }
    
    return($num);
}

## This sub is taken from Egc_library.pm
sub insert_asm_feature {
    my($dbproc,$feat_name,$asmbl_id,$feat_type,$end5,$end3,$assignby, $method, $change_log, $save_history) =@_;
    my($query,$statementHandle,@row,$i,$result);

    $query = "insert asm_feature (feat_name, asmbl_id, feat_type, end5, end3, date, "
             . "feat_method, assignby, change_log, save_history) "  
             . "values (\"$feat_name\", $asmbl_id, \"$feat_type\", $end5, $end3, "
             . "getdate(), \"$method\", \"$assignby\", $change_log, $save_history)";
    
    log_this("query: $query\n");
    
    &do_sql($dbproc, $query);   
    
    unless ($QUERYFAIL) {
        $query = "select feat_id "
               . "from asm_feature "
               . "where feat_name = \"$feat_name\" "
               . "and feat_type = \"$feat_type\"";
        log_this(print "QUERY: $query\n");
        $result = &single_sql($dbproc, $query);
        return($result);
    }
}

## This sub is taken from Egc_library.pm
sub insert_phys_ev {
    my($dbproc, $feat_name, $ev, $by) = @_;
    my($query, $id);
    
    $query = "insert phys_ev (feat_name, ev_type, assignby, datestamp) "
    . "values (\"$feat_name\",\"$ev\", \"$by\", getdate())";
    
    log_this("query: $query\n");
    &do_sql($dbproc, $query);
    
    unless ($QUERYFAIL) {
        $query = "select id "
               . "from phys_ev "
               . "where feat_name = \"$feat_name\" "
               . "and ev_type = \"$ev\"";
        log_this("query: $query\n");
        $id = &single_sql($dbproc, $query);
        return($id);
    }
}

## This sub is taken from Egc_library.pm
sub insert_feat_link {
    my($dbproc,$child,$parent,$assignby,$tdate) = @_;
    my($query, $new_id);
    
    if ($tdate eq "now") {
        $query = "insert feat_link (parent_feat,child_feat,assignby,datestamp) "
               . "values (\"$parent\",\"$child\",\"$assignby\",getdate())";
    } else {
        if ($tdate eq ""){
            $tdate = "Aug 2 1968";
        }
        $query = "insert feat_link (parent_feat,child_feat,assignby,datestamp) "
               . "values (\"$parent\",\"$child\",\"$assignby\",\"$tdate\")";
    }
    log_this("query: $query\n");
    $new_id = &do_sql($dbproc,$query);
}

## This sub is taken from Egc_library.pm
sub delete_gene_predictions {
    my ($dbproc, $asmbl_id, $ev_type) = @_;
    ## gather model and exon feat_names
    my $query = "select a_model.feat_name, a_exon.feat_name \n"
              . "from asm_feature a_model, asm_feature a_exon, feat_link f, phys_ev p_exon, phys_ev p_model \n"
              . "where a_model.feat_name = f.parent_feat and a_model.feat_type = \"model\" \n"
              . "and a_model.feat_name = p_model.feat_name and p_model.ev_type = \"$ev_type\" \n"
              . "and a_model.asmbl_id = $asmbl_id and a_exon.asmbl_id = $asmbl_id \n"
              . "and f.child_feat = a_exon.feat_name and a_exon.feat_type = \"exon\" \n"
              . "and a_exon.feat_name = p_exon.feat_name and p_exon.ev_type = \"$ev_type\" \n";

    my (@results) = &do_sql ($dbproc, $query);
    my %models;
    foreach my $result(@results) {
        my ($model_feat_name, $exon_feat_name) = split (/\t/, $result);
        $models{$model_feat_name}->{$exon_feat_name} = 1;
    }
    foreach my $model(keys %models) {
        #delete model info
        my $query = "delete from asm_feature where feat_name = \"$model\" \n";
        &runMod ($dbproc, $query);
        $query = "delete from feat_link where parent_feat = \"$model\" or child_feat = \"$model\" \n";
        &runMod ($dbproc, $query);
        $query = "delete from phys_ev where feat_name = \"$model\" \n";
        &runMod ($dbproc, $query);
        ## rid exons 
        foreach my $exon (keys %{$models{$model}}) {
            my $query = "delete asm_feature where feat_name = \"$exon\" and not exists (select * from phys_ev where asm_feature.feat_name = phys_ev.feat_name and phys_ev.ev_type != \"$ev_type\")\n";
            &runMod ($dbproc, $query);
            $query = "delete phys_ev where feat_name = \"$exon\" and ev_type = \"$ev_type\" \n";
            &runMod ($dbproc, $query);
        }
    }
}

## This sub is taken from Egc_library.pm
sub runMod {
    my($dbproc,$query, @values) = @_;
    my($statementHandle,$result);

    log_this("$query\nValues: @values\n");
    $result = &first_result_sql($dbproc, $query, undef, @values);
    return($result);
}

## This sub is taken from Egc_library.pm
sub single_sql {
    my($dbproc,$query) = @_;
    return(&last_result_sql($dbproc, $query));
}

## This sub is taken from Egc_library.pm
sub first_result_sql {
    my ($dbproc, $query, $delimeter, @values) = @_;
    my @results = &do_sql ($dbproc, $query, $delimeter, @values);
    return ($results[0]);
}

## This sub is taken from Egc_library.pm
sub last_result_sql {
    my ($dbproc, $query) = @_;
    my @results = &do_sql ($dbproc, $query);
    return ($results[$#results]);
}

## This sub is taken from Egc_library.pm
sub do_sql {
    my ($dbproc,$query,$delimeter, @values) = @_;
    my ($statementHandle,@x,@results);
    my ($i,$result,@row);
    unless ($delimeter) {
        $delimeter = "\t";
    }
    
    ## Use $QUERYFAIL Global variable to detect query failures.
    $QUERYFAIL = 0; #initialize
    log_this("query: $query\nValues: @values\n");
    $statementHandle = $dbproc->prepare($query);
    if ( !defined $statementHandle) {
        print "Cannot prepare statement: $DBI::errstr\n";
        $QUERYFAIL = 1;
    } else {
        # Keep trying to query thru deadlocks:
        do {
            $QUERYFAIL = 0; #initialize
            eval {
                $statementHandle->execute(@values) || print STDERR "failed query: $query\nValues: @values\n";
                if($statementHandle->{syb_more_results} ne "") {
                    while ( @row = $statementHandle->fetchrow() ) {
                        push(@results,join($delimeter,@row));
                    }
                }
            };
            ## exception handling code:
            if ($@) {
                print STDERR "failed query: $query\nErrors: $DBI::errstr\n";
                $QUERYFAIL = 1;
            }
            
        } while ($statementHandle->errstr() =~ /deadlock|Insufficient amount of memory/);
        #release the statement handle resources
        $statementHandle->finish;
    }
    
    if ($QUERYFAIL) {
        die $DBI::errstr;
    }
    
    return(@results);
}

## This sub is taken from Egc_library.pm
sub connectToDb {
    my($server,$dbtype,$user,$passwd,$db) = @_;
    my($dbproc);
    #print "server: $server dbtype: $dbtype user: $user passwd: $passwd db: $db\n";
    $dbproc = (DBI->connect("dbi:$dbtype:server=$server; packetSize=8092",$user, $passwd));
    
    if ( !defined $dbproc ) {
        log_die("Cannot connect to Sybase server: $DBI::errstr");
    }
    $dbproc->{RaiseError} = 1; #turn on raise error.  Must use exception handling now.
    $dbproc->{PrintError} = 1; #turn on print error.
    $dbproc->do("use $db");
    return($dbproc);
}

## log or display messages
sub log_this {
    if (defined($options{'log'})) {
        print LOG $_[0]."\n";
    } elsif (defined($options{'debug'})) {
        print STDERR $_[0]."\n";
    }
}

## non-fatal error logging
sub log_error {
        log_this("ERROR: ".$_[0]."\n");
}

## fatal error log and die
sub log_die {
    if (defined($options{'log'})) {
        log_this("FATAL ERROR:".$_[0]."\n");
        close LOG;
    } else {
        log_this("FATAL ERROR:".$_[0]."\n");
    }
    die();
}

## check that the options provided are ok
sub checkOptions {
    ## database and input_list are required
    unless ( defined($options{server}) && defined($options{database}) && defined($options{input_list}) ) {
        print STDERR "server, database and input_list options are required\n";
        pod2usage( {-exitval=>1, -verbose => 2, -output => \*STDOUT} );
    }

    ## make sure input list exists
    unless ( -e $options{input_list} ) {
        print STDERR "input_list '".$options{'input_list'}."' does not exist\n";
        exit(1);
    }
}
