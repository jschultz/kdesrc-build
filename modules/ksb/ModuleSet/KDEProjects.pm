package ksb::ModuleSet::KDEProjects 0.20;

# Class: ModuleSet::KDEProjects
#
# This represents a collective grouping of modules that share common options,
# and are obtained via the kde-projects database at
# https://projects.kde.org/kde_projects.xml
#
# See also the parent class ModuleSet, from which most functionality is derived.
#
# The only changes here are to allow for expanding out module specifications
# (except for ignored modules), by using KDEXMLReader.
#
# See also: ModuleSet

use strict;
use warnings;
use 5.014;
no if $] >= 5.018, 'warnings', 'experimental::smartmatch';

our @ISA = qw(ksb::ModuleSet);

use ksb::Module;
use ksb::Debug;
use ksb::KDEXMLReader 0.20;
use ksb::BuildContext 0.20;
use ksb::Util;

sub new
{
    my $self = ksb::ModuleSet::new(@_);
    $self->{projectsDataReader} = undef; # Will be filled in when we get fh
    return $self;
}

# Simple utility subroutine. See List::Util's perldoc
sub none_true
{
    ($_ && return 0) for @_;
    return 1;
}

sub _createMetadataModule
{
    my ($ctx, $moduleName) = @_;
    my $metadataModule = ksb::Module->new($ctx, $moduleName =~ s,/,-,r);

    # Hardcode the results instead of expanding out the project info
    $metadataModule->setOption('repository', "kde:$moduleName");
    $metadataModule->setOption('#xml-full-path', $moduleName);
    $metadataModule->setOption('#branch:stable', 'master');
    $metadataModule->setScmType('metadata');
    $metadataModule->setOption('disable-snapshots', 1);
    $metadataModule->setOption('branch', 'master');

    my $moduleSet = ksb::ModuleSet::KDEProjects->new($ctx, '<kde-projects dependencies>');
    $metadataModule->setModuleSet($moduleSet);

    # Ensure we only ever try to update source, not build.
    $metadataModule->phases()->phases('update');

    return $metadataModule;
}

# Function: getDependenciesModule
#
# Static. Returns a <Module> that can be used to download the
# 'kde-build-metadata' module, which itself contains module dependencies
# in the KDE build system.  The module is meant to be held by the <BuildContext>
#
# Parameters:
#  ctx - the <ksb::BuildContext> for this script execution.
sub getDependenciesModule
{
    my $ctx = assert_isa(shift, 'ksb::BuildContext');
    return _createMetadataModule($ctx, 'kde-build-metadata');
}

# Function: getProjectMetadataModule
#
# Static. Returns a <Module> that can be used to download the
# 'repo-metadata' module, which itself contains information on each
# repository in the KDE build system (though currently not
# dependencies).  The module is meant to be held by the <BuildContext>
#
# Parameters:
#  ctx - the <ksb::BuildContext> for this script execution.
sub getProjectMetadataModule
{
    my $ctx = assert_isa(shift, 'ksb::BuildContext');
    return _createMetadataModule($ctx, 'sysadmin/repo-metadata');
}

# Function: _expandModuleCandidates
#
# A class method which goes through the modules in our search list (assumed to
# be found in kde-projects), expands them into their equivalent git modules,
# and returns the fully expanded list. Non kde-projects modules cause an error,
# as do modules that do not exist at all within the database.
#
# *Note*: Before calling this function, the kde-projects database itself must
# have been downloaded first. See getProjectMetadataModule, which ties to the
# BuildContext.
#
# Modules that are part of a module-set requiring a specific branch, that don't
# have that branch, are still listed in the return result since there's no way
# to tell that the branch won't be there.  These should be removed later.
#
# Parameters:
#  ctx - The <BuildContext> in use.
#  moduleSearchItem - The search description to expand in ksb::Modules. See
#  _projectPathMatchesWildcardSearch for a description of the syntax.
#
# Returns:
#  @modules - List of expanded git <Modules>.
#
# Throws:
#  Runtime - if the kde-projects database was required but couldn't be
#  downloaded or read.
#  Runtime - if the git-desired-protocol is unsupported.
#  Runtime - if an "assumed" kde-projects module was not actually one.
sub _expandModuleCandidates
{
    my $self = assert_isa(shift, 'ksb::ModuleSet::KDEProjects');
    my $ctx = assert_isa(shift, 'ksb::BuildContext');
    my $moduleSearchItem = shift;

    my $srcdir = $ctx->getSourceDir();

    my $xmlReader = $ctx->getProjectDataReader();
    my @allXmlResults = $xmlReader->getModulesForProject($moduleSearchItem);

    croak_runtime ("Unknown KDE project: $moduleSearchItem") unless @allXmlResults;

    # It's possible to match modules which are marked as inactive on
    # projects.kde.org, elide those.
    my @xmlResults = grep { $_->{'active'} } (@allXmlResults);

    if (!@xmlResults) {
        warning (" y[b[*] Module y[$moduleSearchItem] is apparently XML-based, but contains no\n" .
                 "active modules to build!");
        my $count = scalar @allXmlResults;
        if ($count > 0) {
            warning ("\tAlthough no active modules are available, there were\n" .
                     "\t$count inactive modules. Perhaps the git modules are not ready?");
        }
    }

    # Setup module options.
    my @moduleList;
    my @ignoreList = $self->modulesToIgnore();

    foreach (@xmlResults) {
        my $result = $_;
        my $repo = $result->{'repo'};

        # Prefer kde: alias to normal clone URL.
        $repo =~ s(^git://anongit\.kde\.org/)(kde:);

        my $newModule = ksb::Module->new($ctx, $result->{'name'});
        $self->_initializeNewModule($newModule);
        $newModule->setOption('repository', $repo);
        $newModule->setOption('#xml-full-path', $result->{'fullName'});
        $newModule->setOption('#branch:stable', undef);
        $newModule->setOption('#found-by', $result->{found_by});
        $newModule->setScmType('proj');

        if (none_true(
                map {
                    ksb::KDEXMLReader::_projectPathMatchesWildcardSearch(
                        $result->{'fullName'},
                        $_
                    )
                } (@ignoreList)))
        {
            push @moduleList, $newModule;
        }
        else {
            debug ("--- Ignoring matched active module $newModule in module set " .
                $self->name());
        }
    };

    return @moduleList;
}

# This function should be called after options are read and build metadata is
# available in order to convert this module set to a list of ksb::Module.
# Any modules ignored by this module set are excluded from the returned list.
# The modules returned have not been added to the build context.
sub convertToModules
{
    my ($self, $ctx) = @_;

    my @moduleList; # module names converted to ksb::Module objects.
    my %foundModules;

    # Setup default options for each module
    # Extraction of relevant XML modules will be handled immediately after
    # this phase of execution.
    for my $moduleItem ($self->modulesToFind()) {
        # We might have already grabbed the right module recursively.
        next if exists $foundModules{$moduleItem};

        # eval in case the XML processor throws an exception.
        undef $@;
        my @candidateModules = eval {
            $self->_expandModuleCandidates($ctx, $moduleItem);
        };

        if ($@) {
            die $@ if had_an_exception(); # Forward exception objects up
            croak_runtime("The XML for the KDE Project database could not be understood: $@");
        }

        my @moduleNames = map { $_->name() } @candidateModules;
        @foundModules{@moduleNames} = (1) x @moduleNames;
        push @moduleList, @candidateModules;
    }

    if (not scalar @moduleList) {
        warning ("No modules were defined for the module-set " . $self->name());
        warning ("You should use the g[b[use-modules] option to make the module-set useful.");
    }

    return @moduleList;
}

1;
