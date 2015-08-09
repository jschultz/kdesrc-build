package ksb::BuildSystem;

# Base module for the various build systems, includes built-in implementations of
# generic functions and supports hooks for subclasses to provide needed detailed
# functionality.

use strict;
use warnings;
use 5.014;

our $VERSION = '0.20';

use ksb::Debug;
use ksb::Util;
use ksb::StatusView;

use List::Util qw(first);

sub new
{
    my ($class, $module) = @_;
    my $self = bless { module => $module }, $class;

    # This is simply the 'default' build system at this point, also used for
    # KF5.
    if ($class ne 'ksb::BuildSystem::KDE4') {
        _maskGlobalBuildSystemOptions($self);
    }

    return $self;
}

# Removes or masks global build system-related options, so that they aren't
# accidentally picked up for use with our non-default build system.
# Module-specific options are left intact.
sub _maskGlobalBuildSystemOptions
{
    my $self = shift;
    my $module = $self->module();
    my $ctx = $module->buildContext();
    my @buildSystemOptions = qw(
        cmake-options configure-flags custom-build-command cxxflags
        make-options run-tests use-clean-install
    );

    for my $opt (@buildSystemOptions) {
        # If an option is present, and not set at module-level, it must be
        # global. Can't use getOption() method due to recursion.
        if ($ctx->{options}->{$opt} && !$module->{options}->{$opt}) {
            $module->{options}->{$opt} = '';
        }
    }
}

sub module
{
    my $self = shift;
    return $self->{module};
}

# Subroutine to determine if a given module needs to have the build system
# recreated from scratch.
# If so, it returns boolean true.
sub needsRefreshed
{
    my $self = assert_isa(shift, 'ksb::BuildSystem');
    my $module = $self->module();
    my $builddir = $module->fullpath('build');
    my $confFileKey = $self->configuredModuleFileName();

    return 1 if ((not -e "$builddir") ||
        (-e "$builddir/.refresh-me") ||
        $module->getOption("refresh-build") ||
        (($module->getPersistentOption('failure-count') // 0) > 1) ||
        (not -e "$builddir/$confFileKey"));

    return 0;
}

# Returns true if the given subdirectory (reference from the module's root source directory)
# can be built or not. Should be reimplemented by subclasses as appropriate.
sub isSubdirBuildable
{
    return 1;
}

# Returns true if the buildsystem will give percentage-completion updates on its output.
# Such percentage updates will be searched for to update the kdesrc-build status.
sub isProgressOutputSupported
{
    return 0;
}

# If this method returns a non-empty string, then that string is the name
# of an environment variable to prepend the module's installation prefix
# path to. Mostly a hack, but will have to do until there's a better scheme
# for giving integration points for build systems into the actual build
# process.
sub prefixEnvironmentVariable
{
    return undef;
}

# Returns true if the module should have make install run in order to be
# used, or false if installation is not required or possible.
sub needsInstalled
{
    return 1;
}

# This should return a list of executable names that must be present to
# even bother attempting to use this build system. An empty list should be
# returned if there's no required programs.
sub requiredPrograms
{
    return;
}

sub name
{
    return 'generic';
}

# Returns a list of possible build commands to run, any one of which should
# be supported by the build system.
sub buildCommands
{
    # Non Linux systems can sometimes fail to build when GNU Make would work,
    # so prefer GNU Make if present, otherwise try regular make.
    return 'gmake', 'make';
}

# Return value style: boolean
sub buildInternal
{
    my $self = shift;

    return $self->safe_make({
        target => undef,
        message => 'Compiling...',
        'make-options' => [
            split(' ', $self->module()->getOption('make-options')),
        ],
        logbase => 'build',
        subdirs => [
            split(' ', $self->module()->getOption("checkout-only"))
        ],
    }) == 0;
}

# Return value style: boolean
sub configureInternal
{
    # It is possible to make it here if there's no source dir and if we're
    # pretending. If we're not actually pretending then this should be a
    # bug...
    return 1 if pretending();

    croak_internal('We were not supposed to get to this point...');
}

# Returns name of file that should exist (relative to the module's build directory)
# if the module has been configured.
sub configuredModuleFileName
{
    my $self = shift;
    return 'Makefile';
}

# Runs the testsuite for the given module.
# Returns true if a testsuite is present and all tests passed, false otherwise.
sub runTestsuite
{
    my $self = shift;
    my $module = $self->module();

    info ("\ty[$module] does not support the b[run-tests] option");
    return 0;
}

# Used to install a module (that has already been built, tested, etc.)
# All options passed are prefixed to the eventual command to be run.
# Returns boolean false if unable to install, true otherwise.
sub installInternal
{
    my $self = shift;
    my $module = $self->module();
    my @cmdPrefix = @_;

    return $self->safe_make ({
            target => 'install',
            message => "Installing g[$module]",
            'prefix-options' => [@cmdPrefix],
            subdirs => [ split(' ', $module->getOption("checkout-only")) ],
           }) == 0;
}

# Used to uninstall a previously installed module.
# All options passed are prefixed to the eventual command to be run.
# Returns boolean false if unable to uninstall, true otherwise.
sub uninstallInternal
{
    my $self = shift;
    my $module = $self->module();
    my @cmdPrefix = @_;

    return $self->safe_make ({
            target => 'uninstall',
            message => "Uninstalling g[$module]",
            'prefix-options' => [@cmdPrefix],
            subdirs => [ split(' ', $module->getOption("checkout-only")) ],
           }) == 0;
}

# Subroutine to clean the build system for the given module.  Works by
# recursively deleting the directory and then recreating it.
# Returns 0 for failure, non-zero for success.
sub cleanBuildSystem
{
    my $self = assert_isa(shift, 'ksb::BuildSystem');
    my $module = $self->module();
    my $srcdir = $module->fullpath('source');
    my $builddir = $module->fullpath('build');

    if (pretending())
    {
        pretend ("\tWould have cleaned build system for g[$module]");
        return 1;
    }

    # Use an existing directory
    if (-e $builddir && $builddir ne $srcdir)
    {
        info ("\tRemoving files in build directory for g[$module]");

        # This variant of log_command runs the sub prune_under_directory($builddir)
        # in a forked child, so that we can log its output.
        if (log_command($module, 'clean-builddir', [ 'kdesrc-build', 'main::prune_under_directory', $builddir ]))
        {
            error (" r[b[*]\tFailed to clean build directory.  Verify the permissions are correct.");
            return 0; # False for this function.
        }

        # Let users know we're done so they don't wonder why rm -rf is taking so
        # long and oh yeah, why's my HD so active?...
        info ("\tOld build system cleaned, starting new build system.");
    }
    # or create the directory
    elsif (!super_mkdir ($builddir))
    {
        error ("\tUnable to create directory r[$builddir].");
        return 0;
    }

    return 1;
}

# Return convention: boolean
sub createBuildSystem
{
    my $self = assert_isa(shift, 'ksb::BuildSystem');
    my $module = $self->module();
    my $builddir = $module->fullpath('build');

    if (! -e "$builddir" && !super_mkdir("$builddir"))
    {
        error ("\tUnable to create build directory for r[$module]!!");
        return 0;
    }

    return 1;
}

# Subroutine to run the build command with the arguments given by the
# passed hash.
#
# In addition to finding the proper executable, this function handles the
# step of running the build command for individual subdirectories (as
# specified by the checkout-only option to the module).  Due to the various
# ways the build command is called by this script, it is required to pass
# customization options in a hash:
# {
#    target         => undef, or a valid build target e.g. 'install',
#    message        => 'Compiling.../Installing.../etc.'
#    make-options   => [ list of command line arguments to pass to make. See
#                        make-options ],
#    prefix-options => [ list of command line arguments to prefix *before* the
#                        make command, used for make-install-prefix support for
#                        e.g. sudo ],
#    logbase        => 'base-log-filename',
#    subdirs        => [ list of subdirectories of the module to build,
#                        relative to the module's own build directory. ]
# }
#
# target and message are required. logbase is required if target is left
# undefined, but otherwise defaults to the same value as target.
#
# Note that the make command is based on the results of the 'buildCommands'
# subroutine which should be overridden if necessary by subclasses. Each
# command should be the command name (i.e. no path). The user may override
# the command used (for build only) by using the 'custom-build-command'
# option.
#
# The first command name found which resolves to an executable on the
# system will be used, if no command this function will fail.
#
# The first argument should be the ksb::Module object to be made.
# The second argument should be the reference to the hash described above.
#
# Returns 0 on success, non-zero on failure (shell script style)
sub safe_make (@)
{
    my ($self, $optsRef) = @_;
    assert_isa($self, 'ksb::BuildSystem');
    my $module = $self->module();

    # Convert the path to an absolute path since I've encountered a sudo
    # that is apparently unable to guess.  Maybe it's better that it
    # doesn't guess anyways from a security point-of-view.
    my $buildCommand = first { absPathToExecutable($_) } $self->buildCommands();
    my @buildCommandLine = $buildCommand;

    # Check for custom user command. We support command line options being
    # passed to the command as well.
    my $userCommand = $module->getOption('custom-build-command');
    if ($userCommand) {
        @buildCommandLine = split_quoted_on_whitespace($userCommand);
        $buildCommand = absPathToExecutable($buildCommandLine[0]);
    }

    if (!$buildCommand) {
        $buildCommand = $userCommand || $self->buildCommands();
        error (" r[b[*] Unable to find the g[$buildCommand] executable!");
        return 1;
    }

    # Make it prettier if pretending (Remove leading directories).
    $buildCommand =~ s{^/.*/}{} if pretending();
    shift @buildCommandLine; # $buildCommand is already the first entry.

    # Simplify code by forcing lists to exist.
    $optsRef->{'prefix-options'} //= [ ];
    $optsRef->{'make-options'} //= [ ];
    $optsRef->{'subdirs'} //= [ ];

    my @prefixOpts = @{$optsRef->{'prefix-options'}};

    # If using sudo ensure that it doesn't wait on tty, but tries to read from
    # stdin (which should fail as we redirect that from /dev/null)
    if (@prefixOpts && $prefixOpts[0] eq 'sudo' && !grep { /^-S$/ } @prefixOpts)
    {
        splice (@prefixOpts, 1, 0, '-S'); # Add -S right after 'sudo'
    }

    # Assemble arguments
    my @args = (@prefixOpts, $buildCommand, @buildCommandLine);
    push @args, $optsRef->{target} if $optsRef->{target};
    push @args, @{$optsRef->{'make-options'}};

    # Will be output by _runBuildCommand
    my $buildMessage = $optsRef->{message};

    # Here we're attempting to ensure that we either run the build command
    # in each subdirectory, *or* for the whole module, but not both.
    my @dirs = @{$optsRef->{subdirs}};
    push (@dirs, "") if scalar @dirs == 0;

    for my $subdir (@dirs)
    {
        # Some subdirectories shouldn't have the build command run within
        # them.
        next unless $self->isSubdirBuildable($subdir);

        my $logname = $optsRef->{logbase} // $optsRef->{logfile} // $optsRef->{target};

        if ($subdir ne '')
        {
            $logname = $logname . "-$subdir";

            # Remove slashes in favor of something else.
            $logname =~ tr{/}{-};

            # Mention subdirectory that we're working on, move ellipsis
            # if present.
            if ($buildMessage =~ /\.\.\.$/) {
                $buildMessage =~ s/(\.\.\.)?$/ subdirectory g[$subdir]$1/;
            }
        }

        my $builddir = $module->fullpath('build') . "/$subdir";
        $builddir =~ s/\/*$//; # Remove trailing /

        p_chdir ($builddir);

        my $result = $self->_runBuildCommand($buildMessage, $logname, \@args);
        return $result if $result;
    };

    return 0;
}

# Subroutine to run make and process the build process output in order to
# provide completion updates.  This procedure takes the same arguments as
# log_command() (described here as well), except that the callback argument
# is not used.
#
# First parameter is the message to display to the user while the build
#   happens.
# Second parameter is the name of the log file to use (relative to the log
#   directory).
# Third parameter is a reference to an array with the command and its
#   arguments.  i.e. ['command', 'arg1', 'arg2']
# The return value is the shell return code, so 0 is success, and non-zero
#   is failure.
sub _runBuildCommand
{
    my ($self, $message, $filename, $argRef) = @_;
    my $module = $self->module();

    # There are situations when we don't want (or can't get) progress output:
    # 1. Not using CMake (i.e. Qt)
    # 2. If we're not printing to a terminal.
    # 3. When we're debugging (we'd interfere with debugging output).
    if (!$self->isProgressOutputSupported() || ! -t STDERR || debugging())
    {
        return log_command($module, $filename, $argRef);
    }

    my $statusViewer = ksb::StatusView->new();
    $statusViewer->setStatus("\t$message");
    $statusViewer->update();

    # w00t.  Check out the closure!  Maks would be so proud.
    my $log_command_callback = sub {
        my $input = shift;
        if (not defined $input) {
            # End of input, cleanup.
            $statusViewer->releaseTTY();
            return;
        }

        my ($percentage) = ($input =~ /^\[\s*([0-9]+)%]/);
        if ($percentage) {
            $statusViewer->setProgressTotal(100);
            $statusViewer->setProgress($percentage);
        }
        else {
            my ($x, $y) = ($input =~ /^\[([0-9]+)\/([0-9]+)] /);
            if ($x && $y) {
                # ninja-syntax
                $statusViewer->setProgressTotal($y);
                $statusViewer->setProgress($x);
            }
        }
    };

    return log_command($module, $filename, $argRef, {
            callback => $log_command_callback
        });
}

1;
