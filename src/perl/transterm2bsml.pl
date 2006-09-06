#!/usr/local/bin/perl

BEGIN{foreach (@INC) {s/\/usr\/local\/packages/\/local\/platform/}};
use lib (@INC,$ENV{"PERL_MOD_DIR"});
no lib "$ENV{PERL_MOD_DIR}/i686-linux";
no lib ".";


=head1 NAME

transterm2bsml.pl - turns tranterm raw output to bsml

=head1 SYNOPSIS

USAGE: template.pl 
            --input_list=/path/to/some/transterm.raw.list
            --input_file=/path/to/some/transterm.raw
            --output=/path/to/transterm.bsml
            --project=aa1
          [ --log=/path/to/file.log
            --debug=4
            --help
          ]

=head1 OPTIONS

=head1  DESCRIPTION

=head1  INPUT

=head1  OUTPUT
 
=head1  CONTACT

    Kevin Galens
    kgalens@tigr.org

=cut

use strict;
use warnings;
use Getopt::Long qw(:config no_ignore_case no_auto_abbrev pass_through);
use Pod::Usage;
use BSML::BsmlBuilder;
use Workflow::Logger;
use Workflow::IdGenerator;
use Data::Dumper;

####### GLOBALS AND CONSTANTS ###########
my @inputFiles;
my $project;
my $output;
my $debug;
my $idMaker;
########################################

my %options = ();
my $results = GetOptions (\%options, 
                          'input_list|i=s',
                          'input_file|f=s',
                          'output|o=s',
                          'project|p=s',
                          'id_repository|d=s',
                          'log|l=s',
                          'debug=s',
                          'help|h') || &_pod;

#Setup the logger
my $logfile = $options{'log'} || Workflow::Logger::get_default_logfilename();
my $logger = new Workflow::Logger('LOG_FILE'=>$logfile,
				  'LOG_LEVEL'=>$options{'debug'});
$logger = $logger->get_logger();

# Check the options.
&check_parameters(\%options);

foreach my $file (@inputFiles) {
    my $tmp = &parseTranstermData($file);
    my $data;
    $data->{$file} = $tmp;
    my $bsml = &generateBsml($data);
    $bsml->write($output);
}

exit(0);

######################## SUB ROUTINES #######################################
sub parseTranstermData {
    my $file = shift;
    my $retval;
    my $seq = "";
    open(IN, "< $file") ||
        &_die("Unable to open the transterm raw file $file ($!)");

    while(<IN>) {
        if(/^SEQUENCE\s(.*?)\s.*length\s(\d+)/) {
            $seq = $1;
            $retval->{$seq}->{'length'} = $2;
        } elsif(/^\s+TERM/) {
            my @tmp = split(/\s+/);

            my $strand = 0; #0 means forward strand.

            my ($start, $stop) = ($tmp[3], $tmp[5]);
            if($start > $stop) {
                my $tmpBound = $start;
                $start = $stop;
                $stop = $tmpBound;
                $strand = 1;
            }

            $retval->{$seq}->{$tmp[2]}->{'start'} = $start;
            $retval->{$seq}->{$tmp[2]}->{'stop'} = $stop;
            $retval->{$seq}->{$tmp[2]}->{'strand'} = $strand;
            $retval->{$seq}->{$tmp[2]}->{'conf'} = $tmp[8];
            $retval->{$seq}->{$tmp[2]}->{'hp'} = $tmp[9];
            $retval->{$seq}->{$tmp[2]}->{'tail'} = $tmp[10];

        }

    }

    close(IN);
    
    return $retval;

}

sub generateBsml {
    my $data = shift;
    my $doc = new BSML::BsmlBuilder();

    foreach my $file(keys %{$data}) {
        foreach my $seq(keys %{$data->{$file}}) {
    
            #Try to figure out the class
            my $class = 'sequence';
            $class = $1 if($seq =~ /\w+\.(\w+)\./);
            
            my $seqObj = $doc->createAndAddSequence( $seq, $seq, $data->{$seq}->{'length'}, 'dna', $class );
            $doc->createAndAddSeqDataImport( $seqObj, 'fasta', $file, $seq, $seq );
            $doc->createAndAddLink( $seqObj, 'analysis', '#transterm_analysis', 'input_of' );
            my $featTable = $doc->createAndAddFeatureTable($seqObj);

            #Start adding features to the sequence
            my ($key, $term);
            while(($key, $term) = each(%{$data->{$file}->{$seq}})) {
                next if($key eq 'length');                
                
                my $id = $idMaker->next_id( 'type' => 'terminator', 'project' => $project );
                my $feat = $doc->createAndAddFeature( $featTable, $seq, $seq, 'terminator');
                $feat->addBsmlLink('analysis', '#transterm_analysis', 'computed_by');
                $feat->addBsmlIntervalLoc($data->{$file}->{$seq}->{$key}->{'start'},
                                          $data->{$file}->{$seq}->{$key}->{'stop'},
                                          $data->{$file}->{$seq}->{$key}->{'strand'});
                $doc->createAndAddBsmlAttribute( $feat, 'confidence_score', 
                                                 $data->{$file}->{$seq}->{$key}->{'conf'} );
                $doc->createAndAddBsmlAttribute( $feat, 'hairpin_score',
                                                 $data->{$file}->{$seq}->{$key}->{'hp'} );
                $doc->createAndAddBsmlAttribute( $feat, 'tail_score',
                                                 $data->{$file}->{$seq}->{$key}->{'tail'} );
            }
        }

    $doc->createAndAddAnalysis( 'id' => 'transterm_analysis',
                                'sourcename' => $file );
    }
    return $doc;
}

sub check_parameters {
    my $options = shift;

    my $error = "";

    &_pod if($options{'help'});

    if($options{'input_list'}) {
        $error .= "Option input_list ($options{'input_list'}) does not exist\n" unless(-e $options{'input_list'});
        open(IN, "< $options{'input_list'}") || &_die("Unable to open $options{'input_list'} ($!)");
        @inputFiles = <IN>;
        close(IN);
    }
    if($options{'input_file'}) {
        $error .= "Option input_file ($options{'input_file'}) does not exist\n" unless(-e $options{'input_file'});
        push(@inputFiles, $options{'input_file'});
    }
    unless($options{'input_list'} || $options{'input_file'}) {
        $error .= "Either option input_list or input_file is required\n";
    }

    unless($options{'output'}) {
        $error .= "Option output is required\n";
    } else {
        $output = $options{'output'};
    }

    unless($options{'project'}) {
        $error .= "Option project is required\n";
    } else {
        $project = $options{'project'};
    }

    unless($options{'id_repository'}) {
        $error .= "Option id_repository is required\n";
    } else {
        $idMaker = new Workflow::IdGenerator( 'id_repository' => $options{'id_repository'} );
        $idMaker->set_pool_size('terminator' => 25 );
    }

    if($options{'debug'}) {
        $debug = $options{'debug'};
    }
    
    unless($error eq "") {
        &_die($error);
    }
    
}

sub _pod {   
    pod2usage( {-exitval => 0, -verbose => 2, -output => \*STDERR} );
}

sub _die {
    my $msg = shift;
    $logger->logdie($msg);
}
