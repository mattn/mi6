use v6;
use App::Mi6::Template;
use File::Find;
use Shell::Command;

unit class App::Mi6;

has $!author = qx{git config --global user.name}.chomp;
has $!email  = qx{git config --global user.email}.chomp;
has $!year   = Date.today.year;

my $to-module = -> $file {
    $file.subst('lib/', '').subst('/', '::', :g).subst(/\.pm6?$/, '');
};
my $to-file = -> $module {
    'lib/' ~ $module.subst('::', '/', :g) ~ '.pm6';
};

multi method cmd('new', $module is copy) {
    $module ~~ s:g/ '-' /::/;
    my $main-dir = $module;
    $main-dir ~~ s:g/ '::' /-/;
    die "Already exists $main-dir" if $main-dir.IO ~~ :d;
    mkpath($main-dir);
    chdir($main-dir); # XXX temp $*CWD
    my $module-file = $to-file($module);
    my $module-dir = $module-file.IO.dirname.Str;
    mkpath($_) for $module-dir, "t", "bin";
    my %content = App::Mi6::Template::template(:$module, :$!author, :$!email, :$!year);
    my %map = <<
        $module-file module
        t/01-basic.t test
        LICENSE      license
        .gitignore   gitignore
        .travis.yml  travis
    >>;
    for %map.kv -> $f, $c {
        spurt($f, %content{$c});
    }
    self.cmd("build");
    my $devnull = open $*SPEC.devnull, :w;
    run "git", "init", ".", :out($devnull);
    $devnull.close;
    run "git", "add", ".";
    note "Successfully created $main-dir";
}

multi method cmd('build') {
    my ($module, $module-file) = guess-main-module();
    regenerate-readme($module-file);
    self.regenerate-meta-info($module);
    build();
}

multi method cmd('test', @file, Bool :$verbose, Int :$jobs) {
    self.cmd('build');
    my $exitcode = test(@file, :$verbose, :$jobs);
    exit $exitcode;
}

multi method cmd('release') {
    my ($module, $module-file) = guess-main-module();
    my ($user, $repo) = guess-user-and-repo();
    die "Cannot find user and repository settting" unless $repo;
    my $meta-file = <META6.json META.info>.grep({.IO ~~ :f & :!l})[0];
    print "\n" ~ qq:to/EOF/ ~ "\n";
      Are you ready to release your module? Congrats!
      For this, follow these steps:

      1. Fork https://github.com/perl6/ecosystem repository.
      2. Add https://raw.githubusercontent.com/$user/$repo/master/$meta-file to META.list.
      3. And raise a pull request!

      Once your pull request is merged, we can install your module by:
      \$ panda install $module
    EOF
}

sub withp6lib(&code) {
    # copy from Panda::Common::withp6lib
    my $old = %*ENV<PERL6LIB>:exists ?? %*ENV<PERL6LIB> !! False;
    LEAVE {
        if $old {
            %*ENV<PERL6LIB> = $old;
        } else {
            %*ENV<PERL6LIB>:delete;
        }
    }
    my $new = "$*CWD/blib/lib".IO.e ?? "$*CWD/blib/lib" !! "$*CWD/lib";
    %*ENV<PERL6LIB> = $new ~ ($old ?? ",$old" !! "");
    &code();
}

sub build() {
    return unless "Build.pm".IO.e;
    require Panda::Builder;
    note '==> Execute Panda::Builder.build($*CWD)';
    ::("Panda::Builder").build($*CWD);
}

sub test(@file, Bool :$verbose, Int :$jobs) {
    withp6lib {
        my @option = "-r";
        @option.push("-v") if $verbose;
        @option.push("-j", $jobs) if $jobs;
        if @file.elems == 0 {
            @file = <t xt>.grep({.IO.d});
        }
        my @command = "prove", "-e", $*EXECUTABLE, |@option, |@file;
        note "==> Set PERL6LIB=%*ENV<PERL6LIB>";
        note "==> @command[]";
        my $proc = run |@command;
        $proc.exitcode;
    };
}

sub regenerate-readme($module-file) {
    my @cmd = $*EXECUTABLE, "--doc=Markdown", $module-file;
    my $p = withp6lib { run |@cmd, :out };
    die "Failed @cmd[]" if $p.exitcode != 0;
    my $markdown = $p.out.slurp-rest;
    my ($user, $repo) = guess-user-and-repo();
    my $header = do if $user and ".travis.yml".IO.e {
        "[![Build Status](https://travis-ci.org/$user/$repo.svg?branch=master)]"
            ~ "(https://travis-ci.org/$user/$repo)"
            ~ "\n\n";
    } else {
        "";
    }

    spurt "README.md", $header ~ $markdown;
}

method regenerate-meta-info($module) {
    my $meta-file = <META6.json META.info>.grep({.IO ~~ :f & :!l})[0];
    my $already = $meta-file.defined ?? from-json $meta-file.IO.slurp !! {};

    my $authors = do if $already<authors> {
        $already<authors>;
    } elsif $already<author> {
        [$already<author>];
    } else {
        [ $!author ];
    };

    my %new-meta =
        name        => $module,
        perl        => "v6",
        authors     => $authors,
        depends     => $already<depends> || [],
        description => $already<description> || "",
        provides    => find-provides(),
        source-url  => $already<source-url> || find-source-url(),
        version     => $already<version> || "*",
    ;
    %new-meta{$_} = $already{$_} for <build-depends test-depends>.grep({$already{$_}});
    ($meta-file || "META6.json").IO.spurt: to-json(%new-meta) ~ "\n";
}

sub find-source-url() {
    try my @line = qx{git remote -v 2>/dev/null};
    return "" unless @line;
    my $url = gather for @line -> $line {
        my ($, $url) = $line.split(/\s+/);
        if $url {
            take $url;
            last;
        }
    }
    return "" unless $url;
    $url .= Str;
    $url ~~ s/^https?/git/; # panda does not support http protocol
    if $url ~~ m/'git@' $<host>=[.+] ':' $<repo>=[<-[:]>+] $/ {
        $url = "git://$<host>/$<repo>";
    } elsif $url ~~ m/'ssh://git@' $<rest>=[.+] / {
        $url = "git://$<rest>";
    }
    $url;
}

sub guess-user-and-repo() {
    my $url = find-source-url();
    return if $url eq "";
    if $url ~~ m{ (git|https?) '://'
        [<-[/]>+] '/'
        $<user>=[<-[/]>+] '/'
        $<repo>=[.+?] [\.git]?
    $} {
        return $/<user>, $/<repo>;
    } else {
        return;
    }
}

sub find-provides() {
    my %provides = find(dir => "lib", name => /\.pm6?$/).list.map(-> $file {
        my $module = $to-module($file.Str);
        $module => $file.Str;
    });
    %provides;
}

sub guess-main-module() {
    die "Must run in the top directory" unless "lib".IO ~~ :d;
    my @module-files = find(dir => "lib", name => /.pm6?$/).list;
    my $num = @module-files.elems;
    given $num {
        when 0 {
            die "Could not determine main module file";
        }
        when 1 {
            my $f = @module-files[0];
            return ($to-module($f), $f);
        }
        default {
            my $dir = $*CWD.basename;
            $dir ~~ s/^ (perl6|p6) '-' //;
            my $module = $dir.split('-').join('/');
            my @found = @module-files.grep(-> $f { $f ~~ m:i/$module . pm6?$/});
            my $f = do if @found == 0 {
                my @f = @module-files.sort: { $^a.chars <=> $^b.chars };
                @f.shift.Str;
            } elsif @found == 1 {
                @found[0].Str;
            } else {
                my @f = @found.sort: { $^a.chars <=> $^b.chars };
                @f.shift.Str;
            }
            return ($to-module($f), $f);
        }
    }
}

=begin pod

=head1 NAME

App::Mi6 - minimal authoring tool for Perl6

=head1 SYNOPSIS

  > mi6 new Foo::Bar # create Foo-Bar distribution
  > cd Foo-Bar
  > mi6 build        # build the distribution and re-generate README.md/META6.json
  > mi6 test         # run tests
  > mi6 release      # release!

=head1 INSTALLATION

  > panda install App::Mi6

=head1 DESCRIPTION

App::Mi6 is a minimal authoring tool for Perl6. Features are:

=item Create minimal distribution skeleton for Perl6

=item Generate README.md from lib/Main/Module.pm6's pod

=item Run tests by C<mi6 test>

=head1 FAQ

=item How can I manage depends, description, ...?

  Write them to META.info directly :)

=item Where is Changes file?

  TODO

=item Where is the spec of META.info or META6.json?

  Maybe https://github.com/perl6/ecosystem/blob/master/spec.pod or http://design.perl6.org/S22.html

=item How do I remove travis badge?

  Remove .travis.yml

=head1 SEE ALSO

L<<https://github.com/tokuhirom/Minilla>>

L<<https://github.com/rjbs/Dist-Zilla>>

=head1 COPYRIGHT AND LICENSE

Copyright 2015 Shoichi Kaji <skaji@cpan.org>

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

=end pod
