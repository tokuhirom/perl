package DynaLoader;

#   And Gandalf said: 'Many folk like to know beforehand what is to
#   be set on the table; but those who have laboured to prepare the
#   feast like to keep their secret; for wonder makes the words of
#   praise louder.'

#   (Quote from Tolkien sugested by Anno Siegel.)
#
# See pod text at end of file for documentation.
# See also ext/DynaLoader/README in source tree for other information.
#
# Tim.Bunce@ig.co.uk, August 1994

require Carp;
require Config;
require AutoLoader;

@ISA=qw(AutoLoader);


sub import { }		# override import inherited from AutoLoader

# enable debug/trace messages from DynaLoader perl code
$dl_debug = $ENV{PERL_DL_DEBUG} || 0 unless defined $dl_debug;

($dl_dlext, $dlsrc, $osname)
	= @Config::Config{'dlext', 'dlsrc', 'osname'};

# Some systems need special handling to expand file specifications
# (VMS support by Charles Bailey <bailey@HMIVAX.HUMGEN.UPENN.EDU>)
# See dl_expandspec() for more details. Should be harmless but
# inefficient to define on systems that don't need it.
$do_expand = ($osname eq 'VMS');

@dl_require_symbols = ();       # names of symbols we need
@dl_resolve_using   = ();       # names of files to link with
@dl_library_path    = ();       # path to look for files

# This is a fix to support DLD's unfortunate desire to relink -lc
@dl_resolve_using = dl_findfile('-lc') if $dlsrc eq "dl_dld.xs";

# Initialise @dl_library_path with the 'standard' library path
# for this platform as determined by Configure
push(@dl_library_path, split(' ',$Config::Config{'libpth'}));

# Add to @dl_library_path any extra directories we can gather from
# environment variables. So far LD_LIBRARY_PATH is the only known
# variable used for this purpose. Others may be added later.
push(@dl_library_path, split(/:/, $ENV{LD_LIBRARY_PATH}))
    if $ENV{LD_LIBRARY_PATH};


# No prizes for guessing why we don't say 'bootstrap DynaLoader;' here.
boot_DynaLoader() if defined(&boot_DynaLoader);


if ($dl_debug) {
    print STDERR "DynaLoader.pm loaded (@INC, @dl_library_path)\n";
    print STDERR "DynaLoader not linked into this perl\n"
	    unless defined(&boot_DynaLoader);
}

1; # End of main code


# The bootstrap function cannot be autoloaded (without complications)
# so we define it here:

sub bootstrap {
    # use local vars to enable $module.bs script to edit values
    local(@args) = @_;
    local($module) = $args[0];
    local(@dirs, $file);

    Carp::confess("Usage: DynaLoader::bootstrap(module)") unless $module;

    # A common error on platforms which don't support dynamic loading.
    # Since it's fatal and potentially confusing we give a detailed message.
    Carp::croak("Can't load module $module, dynamic loading not available in this perl.\n".
	"  (You may need to build a new perl executable which either supports\n".
	"  dynamic loading or has the $module module statically linked into it.)\n")
	unless defined(&dl_load_file);

    my @modparts = split(/::/,$module);
    my $modfname = $modparts[-1];

    # Some systems have restrictions on files names for DLL's etc.
    # mod2fname returns appropriate file base name (typically truncated)
    # It may also edit @modparts if required.
    $modfname = &mod2fname(\@modparts) if defined &mod2fname;

    my $modpname = join('/',@modparts);

    print STDERR "DynaLoader::bootstrap for $module ",
		"(auto/$modpname/$modfname.$dl_dlext)\n" if $dl_debug;

    foreach (@INC) {
	my $dir = "$_/auto/$modpname";
	next unless -d $dir; # skip over uninteresting directories

	# check for common cases to avoid autoload of dl_findfile
	last if ($file=_check_file("$dir/$modfname.$dl_dlext"));

	# no luck here, save dir for possible later dl_findfile search
	push(@dirs, "-L$dir");
    }
    # last resort, let dl_findfile have a go in all known locations
    $file = dl_findfile(@dirs, map("-L$_",@INC), $modfname) unless $file;

    Carp::croak("Can't find loadable object for module $module in \@INC (@INC)")
	unless $file;

    my $bootname = "boot_$module";
    $bootname =~ s/\W/_/g;
    @dl_require_symbols = ($bootname);

    # Execute optional '.bootstrap' perl script for this module.
    # The .bs file can be used to configure @dl_resolve_using etc to
    # match the needs of the individual module on this architecture.
    my $bs = $file;
    $bs =~ s/(\.\w+)?$/\.bs/; # look for .bs 'beside' the library
    if (-s $bs) { # only read file if it's not empty
        print STDERR "BS: $bs ($osname, $dlsrc)\n" if $dl_debug;
        eval { do $bs; };
        warn "$bs: $@\n" if $@;
    }

    # Many dynamic extension loading problems will appear to come from
    # this section of code: XYZ failed at line 123 of DynaLoader.pm.
    # Often these errors are actually occurring in the initialisation
    # C code of the extension XS file. Perl reports the error as being
    # in this perl code simply because this was the last perl code
    # it executed.

    my $libref = dl_load_file($file) or
	Carp::croak("Can't load '$file' for module $module: ".dl_error()."\n");

    my @unresolved = dl_undef_symbols();
    Carp::carp("Undefined symbols present after loading $file: @unresolved\n")
        if @unresolved;

    my $boot_symbol_ref = dl_find_symbol($libref, $bootname) or
         Carp::croak("Can't find '$bootname' symbol in $file\n");

    my $xs = dl_install_xsub("${module}::bootstrap", $boot_symbol_ref, $file);

    # See comment block above
    &$xs(@args);
}


sub _check_file {   # private utility to handle dl_expandspec vs -f tests
    my($file) = @_;
    return $file if (!$do_expand && -f $file); # the common case
    return $file if ( $do_expand && ($file=dl_expandspec($file)));
    return undef;
}


# Let autosplit and the autoloader deal with these functions:
__END__


sub dl_findfile {
    # Read ext/DynaLoader/DynaLoader.doc for detailed information.
    # This function does not automatically consider the architecture
    # or the perl library auto directories.
    my (@args) = @_;
    my (@dirs,  $dir);   # which directories to search
    my (@found);         # full paths to real files we have found
    my $vms = ($osname eq 'VMS');
    my $dl_so = $Config::Config{'so'};	# suffix for shared libraries

    print STDERR "dl_findfile(@args)\n" if $dl_debug;

    # accumulate directories but process files as they appear
    arg: foreach(@args) {
        #  Special fast case: full filepath requires no search
        if (m:/: && -f $_ && !$do_expand) {
	    push(@found,$_);
	    last arg unless wantarray;
	    next;
	}

        # Deal with directories first:
        #  Using a -L prefix is the preferred option (faster and more robust)
        if (m:^-L:) { s/^-L//; push(@dirs, $_); next; }

        #  Otherwise we try to try to spot directories by a heuristic
        #  (this is a more complicated issue than it first appears)
        if (m:/: && -d $_) {   push(@dirs, $_); next; }

        # VMS: we may be using native VMS directry syntax instead of
        # Unix emulation, so check this as well
        if ($vms && /[:>\]]/ && -d $_) {   push(@dirs, $_); next; }

        #  Only files should get this far...
        my(@names, $name);    # what filenames to look for
        if (m:-l: ) {          # convert -lname to appropriate library name
            s/-l//;
            push(@names,"lib$_.$dl_so");
            push(@names,"lib$_.a");
        } else {                # Umm, a bare name. Try various alternatives:
            # these should be ordered with the most likely first
            push(@names,"$_.$dl_so")     unless m/\.$dl_so$/o;
            push(@names,"lib$_.$dl_so")  unless m:/:;
            push(@names,"$_.o")          unless m/\.(o|$dl_so)$/o;
            push(@names,"$_.a")          if !m/\.a$/ and $dlsrc eq "dl_dld.xs";
            push(@names, $_);
        }
        foreach $dir (@dirs, @dl_library_path) {
            next unless -d $dir;
            foreach $name (@names) {
		my($file) = "$dir/$name";
                print STDERR " checking in $dir for $name\n" if $dl_debug;
		$file = _check_file($file);
		if ($file) {
                    push(@found, $file);
                    next arg; # no need to look any further
                }
            }
        }
    }
    if ($dl_debug) {
        foreach(@dirs) {
            print STDERR " dl_findfile ignored non-existent directory: $_\n" unless -d $_;
        }
        print STDERR "dl_findfile found: @found\n";
    }
    return $found[0] unless wantarray;
    @found;
}


sub dl_expandspec {
    my($spec) = @_;
    # Optional function invoked if DynaLoader.pm sets $do_expand.
    # Most systems do not require or use this function.
    # Some systems may implement it in the dl_*.xs file in which case
    # this autoload version will not be called but is harmless.

    # This function is designed to deal with systems which treat some
    # 'filenames' in a special way. For example VMS 'Logical Names'
    # (something like unix environment variables - but different).
    # This function should recognise such names and expand them into
    # full file paths.
    # Must return undef if $spec is invalid or file does not exist.

    my $file = $spec; # default output to input

    if ($osname eq 'VMS') { # dl_expandspec should be defined in dl_vms.xs
	Carp::croak("dl_expandspec: should be defined in XS file!\n");
    } else {
	return undef unless -f $file;
    }
    print STDERR "dl_expandspec($spec) => $file\n" if $dl_debug;
    $file;
}


=head1 NAME

DynaLoader - Dynamically load C libraries into Perl code

dl_error(), dl_findfile(), dl_expandspec(), dl_load_file(), dl_find_symbol(), dl_undef_symbols(), dl_install_xsub(), boostrap() - routines used by DynaLoader modules

=head1 SYNOPSIS

    package YourPackage;
    require DynaLoader;
    @ISA = qw(... DynaLoader ...);
    bootstrap YourPackage;


=head1 DESCRIPTION

This document defines a standard generic interface to the dynamic
linking mechanisms available on many platforms.  Its primary purpose is
to implement automatic dynamic loading of Perl modules.

This document serves as both a specification for anyone wishing to
implement the DynaLoader for a new platform and as a guide for
anyone wishing to use the DynaLoader directly in an application.

The DynaLoader is designed to be a very simple high-level
interface that is sufficiently general to cover the requirements
of SunOS, HP-UX, NeXT, Linux, VMS and other platforms.

It is also hoped that the interface will cover the needs of OS/2, NT
etc and also allow pseudo-dynamic linking (using C<ld -A> at runtime).

It must be stressed that the DynaLoader, by itself, is practically
useless for accessing non-Perl libraries because it provides almost no
Perl-to-C 'glue'.  There is, for example, no mechanism for calling a C
library function or supplying arguments.  It is anticipated that any
glue that may be developed in the future will be implemented in a
separate dynamically loaded module.

DynaLoader Interface Summary

  @dl_library_path
  @dl_resolve_using
  @dl_require_symbols
  $dl_debug
                                                  Implemented in:
  bootstrap($modulename)                               Perl
  @filepaths = dl_findfile(@names)                     Perl

  $libref  = dl_load_file($filename)                   C
  $symref  = dl_find_symbol($libref, $symbol)          C
  @symbols = dl_undef_symbols()                        C
  dl_install_xsub($name, $symref [, $filename])        C
  $message = dl_error                                  C

=over 4

=item @dl_library_path

The standard/default list of directories in which dl_findfile() will
search for libraries etc.  Directories are searched in order:
$dl_library_path[0], [1], ... etc

@dl_library_path is initialised to hold the list of 'normal' directories
(F</usr/lib>, etc) determined by B<Configure> (C<$Config{'libpth'}>).  This should
ensure portability across a wide range of platforms.

@dl_library_path should also be initialised with any other directories
that can be determined from the environment at runtime (such as
LD_LIBRARY_PATH for SunOS).

After initialisation @dl_library_path can be manipulated by an
application using push and unshift before calling dl_findfile().
Unshift can be used to add directories to the front of the search order
either to save search time or to override libraries with the same name
in the 'normal' directories.

The load function that dl_load_file() calls may require an absolute
pathname.  The dl_findfile() function and @dl_library_path can be
used to search for and return the absolute pathname for the
library/object that you wish to load.

=item @dl_resolve_using

A list of additional libraries or other shared objects which can be
used to resolve any undefined symbols that might be generated by a
later call to load_file().

This is only required on some platforms which do not handle dependent
libraries automatically.  For example the Socket Perl extension library
(F<auto/Socket/Socket.so>) contains references to many socket functions
which need to be resolved when it's loaded.  Most platforms will
automatically know where to find the 'dependent' library (e.g.,
F</usr/lib/libsocket.so>).  A few platforms need to to be told the location
of the dependent library explicitly.  Use @dl_resolve_using for this.

Example usage:

    @dl_resolve_using = dl_findfile('-lsocket');

=item @dl_require_symbols

A list of one or more symbol names that are in the library/object file
to be dynamically loaded.  This is only required on some platforms.

=item dl_error()

Syntax:

    $message = dl_error();

Error message text from the last failed DynaLoader function.  Note
that, similar to errno in unix, a successful function call does not
reset this message.

Implementations should detect the error as soon as it occurs in any of
the other functions and save the corresponding message for later
retrieval.  This will avoid problems on some platforms (such as SunOS)
where the error message is very temporary (e.g., dlerror()).

=item $dl_debug

Internal debugging messages are enabled when $dl_debug is set true.
Currently setting $dl_debug only affects the Perl side of the
DynaLoader.  These messages should help an application developer to
resolve any DynaLoader usage problems.

$dl_debug is set to C<$ENV{'PERL_DL_DEBUG'}> if defined.

For the DynaLoader developer/porter there is a similar debugging
variable added to the C code (see dlutils.c) and enabled if Perl was
built with the B<-DDEBUGGING> flag.  This can also be set via the
PERL_DL_DEBUG environment variable.  Set to 1 for minimal information or
higher for more.

=item dl_findfile()

Syntax:

    @filepaths = dl_findfile(@names)

Determine the full paths (including file suffix) of one or more
loadable files given their generic names and optionally one or more
directories.  Searches directories in @dl_library_path by default and
returns an empty list if no files were found.

Names can be specified in a variety of platform independent forms.  Any
names in the form B<-lname> are converted into F<libname.*>, where F<.*> is
an appropriate suffix for the platform.

If a name does not already have a suitable prefix and/or suffix then
the corresponding file will be searched for by trying combinations of
prefix and suffix appropriate to the platform: "$name.o", "lib$name.*"
and "$name".

If any directories are included in @names they are searched before
@dl_library_path.  Directories may be specified as B<-Ldir>.  Any other
names are treated as filenames to be searched for.

Using arguments of the form C<-Ldir> and C<-lname> is recommended.

Example: 

    @dl_resolve_using = dl_findfile(qw(-L/usr/5lib -lposix));


=item dl_expandspec()

Syntax:

    $filepath = dl_expandspec($spec)

Some unusual systems, such as VMS, require special filename handling in
order to deal with symbolic names for files (i.e., VMS's Logical Names).

To support these systems a dl_expandspec() function can be implemented
either in the F<dl_*.xs> file or code can be added to the autoloadable
dl_expandspec() function in F<DynaLoader.pm>.  See F<DynaLoader.pm> for
more information.

=item dl_load_file()

Syntax:

    $libref = dl_load_file($filename)

Dynamically load $filename, which must be the path to a shared object
or library.  An opaque 'library reference' is returned as a handle for
the loaded object.  Returns undef on error.

(On systems that provide a handle for the loaded object such as SunOS
and HPUX, $libref will be that handle.  On other systems $libref will
typically be $filename or a pointer to a buffer containing $filename.
The application should not examine or alter $libref in any way.)

This is function that does the real work.  It should use the current
values of @dl_require_symbols and @dl_resolve_using if required.

    SunOS: dlopen($filename)
    HP-UX: shl_load($filename)
    Linux: dld_create_reference(@dl_require_symbols); dld_link($filename)
    NeXT:  rld_load($filename, @dl_resolve_using)
    VMS:   lib$find_image_symbol($filename,$dl_require_symbols[0])


=item dl_find_symbol()

Syntax:

    $symref = dl_find_symbol($libref, $symbol)

Return the address of the symbol $symbol or C<undef> if not found.  If the
target system has separate functions to search for symbols of different
types then dl_find_symbol() should search for function symbols first and
then other types.

The exact manner in which the address is returned in $symref is not
currently defined.  The only initial requirement is that $symref can
be passed to, and understood by, dl_install_xsub().

    SunOS: dlsym($libref, $symbol)
    HP-UX: shl_findsym($libref, $symbol)
    Linux: dld_get_func($symbol) and/or dld_get_symbol($symbol)
    NeXT:  rld_lookup("_$symbol")
    VMS:   lib$find_image_symbol($libref,$symbol)


=item dl_undef_symbols()

Example

    @symbols = dl_undef_symbols()

Return a list of symbol names which remain undefined after load_file().
Returns C<()> if not known.  Don't worry if your platform does not provide
a mechanism for this.  Most do not need it and hence do not provide it,
they just return an empty list.


=item dl_install_xsub()

Syntax:

    dl_install_xsub($perl_name, $symref [, $filename])

Create a new Perl external subroutine named $perl_name using $symref as
a pointer to the function which implements the routine.  This is simply
a direct call to newXSUB().  Returns a reference to the installed
function.

The $filename parameter is used by Perl to identify the source file for
the function if required by die(), caller() or the debugger.  If
$filename is not defined then "DynaLoader" will be used.


=item boostrap()

Syntax:

bootstrap($module)

This is the normal entry point for automatic dynamic loading in Perl.

It performs the following actions:

=over 8

=item *

locates an auto/$module directory by searching @INC

=item *

uses dl_findfile() to determine the filename to load

=item *

sets @dl_require_symbols to C<("boot_$module")>

=item *

executes an F<auto/$module/$module.bs> file if it exists
(typically used to add to @dl_resolve_using any files which
are required to load the module on the current platform)

=item *

calls dl_load_file() to load the file

=item *

calls dl_undef_symbols() and warns if any symbols are undefined

=item *

calls dl_find_symbol() for "boot_$module"

=item *

calls dl_install_xsub() to install it as "${module}::bootstrap"

=item *

calls &{"${module}::bootstrap"} to bootstrap the module (actually
it uses the function reference returned by dl_install_xsub for speed)

=back

=back


=head1 AUTHOR

Tim Bunce, 11 August 1994.

This interface is based on the work and comments of (in no particular
order): Larry Wall, Robert Sanders, Dean Roehrich, Jeff Okamoto, Anno
Siegel, Thomas Neumann, Paul Marquess, Charles Bailey, myself and others.

Larry Wall designed the elegant inherited bootstrap mechanism and
implemented the first Perl 5 dynamic loader using it.

=cut
