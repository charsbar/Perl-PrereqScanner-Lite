package Perl::PrereqScanner::Lite;
use 5.008005;
use strict;
use warnings;
use Compiler::Lexer;
use CPAN::Meta::Requirements;
use Perl::PrereqScanner::Lite::Constants;

our $VERSION = "0.11";

sub new {
    my ($class) = @_;

    bless {
        lexer          => Compiler::Lexer->new,
        extra_scanners => [],
        module_reqs    => CPAN::Meta::Requirements->new,
    }, $class;
}

sub add_extra_scanner {
    my ($self, $scanner_name) = @_;

    my $extra_scanner = "Perl::PrereqScanner::Lite::Scanner::$scanner_name";
    eval "require $extra_scanner"; ## no critic
    push @{$self->{extra_scanners}}, $extra_scanner;
}

sub scan_string {
    my ($self, $string) = @_;

    my $tokens = $self->{lexer}->tokenize($string);
    $self->_scan($tokens);
}

sub scan_file {
    my ($self, $file) = @_;

    open my $fh, '<', $file or die "Cannot open file: $file";
    my $script = do { local $/; <$fh>; };

    my $tokens = $self->{lexer}->tokenize($script);
    $self->_scan($tokens);
}

sub scan_tokens {
    my ($self, $tokens) = @_;
    $self->_scan($tokens);
}

sub scan_module {
    my ($self, $module) = @_;

    require Module::Path;

    if (defined(my $path = Module::Path::module_path($module))) {
        return $self->scan_file($path);
    }
}

sub _scan {
    my ($self, $tokens) = @_;

    my $module_name    = '';
    my $module_version = 0;

    my $not_decl_module_name = '';

    my $is_in_reglist   = 0;
    my $is_in_usedecl   = 0;
    my $is_in_reqdecl   = 0;
    my $is_inherited    = 0;
    my $is_in_list      = 0;
    my $is_version_decl = 0;
    my $is_prev_module_name = 0;

    my $does_garbage_exist = 0;
    my $does_use_lib = 0;

    TOP:
    for my $token (@$tokens) {
        my $token_type = $token->{type};

        # For require statement
        if ($token_type == REQUIRE_DECL) {
            $is_in_reqdecl = 1;
            next;
        }
        if ($is_in_reqdecl) {
            # e.g.
            #   require Foo;
            if ($token_type == REQUIRED_NAME) {
                $self->_add_minimum($token->{data} => 0);

                $is_in_reqdecl = 0;
                next;
            }

            # e.g.
            #   require Foo::Bar;
            if ($token_type == NAMESPACE || $token_type == NAMESPACE_RESOLVER) {
                $module_name .= $token->{data};
                next;
            }

            # End of declare of require statement
            if ($token_type == SEMI_COLON) {
                if ($module_name) {
                    $self->_add_minimum($module_name => 0);
                }

                $module_name   = '';
                $is_in_reqdecl = 0;
                next;
            }

            next;
        }

        # For use statement
        if ($token_type == USE_DECL) {
            $is_in_usedecl = 1;
            next;
        }
        if ($is_in_usedecl) {
            # e.g.
            #   use Foo;
            #   use parent qw/Foo/;
            if ($token_type == USED_NAME) {
                $module_name = $token->{data};

                if ($module_name eq 'lib') {
                    $self->_add_minimum($module_name, 0);
                    $does_use_lib = 1;
                }

                if ($module_name =~ /(?:base|parent)/) {
                    $is_inherited = 1;
                }
                $is_prev_module_name = 1;
                next;
            }

            # End of declare of use statement
            if ($token_type == SEMI_COLON || $token->{data} eq ';') {
                #                            ~~~~~~~~~~~~~~~~~~~~~ XXX Compiler::Lexer matter?
                if ($module_name && !$does_use_lib) {
                    $self->_add_minimum($module_name => $module_version);
                }

                $module_name    = '';
                $module_version = 0;
                $is_in_reglist  = 0;
                $is_inherited   = 0;
                $is_in_list     = 0;
                $is_in_usedecl  = 0;
                $does_use_lib   = 0;
                $does_garbage_exist  = 0;
                $is_prev_module_name = 0;

                next;
            }

            # e.g.
            #   use Foo::Bar;
            if ($token_type == NAMESPACE || $token_type == NAMESPACE_RESOLVER) {
                $module_name .= $token->{data};
                $is_prev_module_name = 1;
                next;
            }

            # Section for parent/base
            if ($is_inherited) {
                # For qw() notation
                # e.g.
                #   use parent qw/Foo Bar/;
                if ($token_type == REG_LIST) {
                    $is_in_reglist = 1;
                }
                elsif ($is_in_reglist) {
                    if ($token_type == REG_EXP) {
                        for my $_module_name (split /\s+/, $token->{data}) {
                            $self->_add_minimum($_module_name => 0);
                        }
                        $is_in_reglist = 0;
                    }
                }

                # For simply list
                # e.g.
                #   use parent ('Foo' 'Bar');
                elsif ($token_type == LEFT_PAREN) {
                    $is_in_list = 1;
                }
                elsif ($token_type == RIGHT_PAREN) {
                    $is_in_list = 0;
                }
                elsif ($is_in_list) {
                    if ($token_type == STRING || $token_type == RAW_STRING) {
                        $self->_add_minimum($token->{data} => 0);
                    }
                }

                # For string
                # e.g.
                #   use parent "Foo"
                elsif ($token_type == STRING || $token_type == RAW_STRING) {
                    $self->_add_minimum($token->{data} => 0);
                }

                $is_prev_module_name = 0;
                next;
            }

            if ($token_type == DOUBLE || $token_type == INT || $token_type == VERSION_STRING) {
                if (!$module_name) {
                    if (!$does_garbage_exist) {
                        # For perl version
                        # e.g.
                        #   use 5.012;
                        my $perl_version = $token->{data};
                        $self->_add_minimum('perl' => $perl_version);
                        $is_in_usedecl = 0;
                    }
                }
                elsif($is_prev_module_name) {
                    # For module version
                    # e.g.
                    #   use Foo::Bar 0.0.1;'
                    #   use Foo::Bar v0.0.1;
                    #   use Foo::Bar 0.0_1;
                    $module_version = $token->{data};
                }

                $is_prev_module_name = 0;
                next;
            }

            $is_prev_module_name = 0;
            $does_garbage_exist  = 1;
            next;
        }

        for my $extra_scanner (@{$self->{extra_scanners}}) {
            if ($extra_scanner->scan($self, $token, $token_type)) {
                next TOP;
            }
        }
    }

    return $self->{module_reqs};
}

sub _add_minimum {
    my ($self, $module_name, $module_version) = @_;

    if ($module_name) {
        $self->{module_reqs}->add_minimum($module_name => $module_version);
    }
}

1;
__END__

=encoding utf-8

=head1 NAME

Perl::PrereqScanner::Lite - Lightweight Prereqs Scanner for Perl

=head1 SYNOPSIS

    use Perl::PrereqScanner::Lite;

    my $scanner = Perl::PrereqScanner::Lite->new;
    $scanner->add_extra_scanner('Moose');
    my $modules = $scanner->scan_file('path/to/file');

=head1 DESCRIPTION

Perl::PrereqScanner::Lite is the lightweight prereqs scanner for perl.
This scanner uses L<Compiler::Lexer> as tokenizer, therefore processing speed is really fast.

=head1 METHODS

=over 4

=item * new

Create scanner instance.

=item * scan_file($file_path)

Scan and figure out prereqs which is instance of C<CPAN::Meta::Requirements> by file path.

=item * scan_string($string)

Scan and figure out prereqs which is instance of C<CPAN::Meta::Requirements> by source code string written in perl.

e.g.

    open my $fh, '<', __FILE__;
    my $string = do { local $/; <$fh> };
    my $modules = $scanner->scan_string($string);

=item * scan_module($module_name)

Scan and figure out prereqs which is instance of C<CPAN::Meta::Requirements> by module name.

e.g.

    my $modules = $scanner->scan_module('Perl::PrereqScanner::Lite');

=item * scan_tokens($tokens)

Scan and figure out prereqs which is instance of C<CPAN::Meta::Requirements> by tokens of L<Compiler::Lexer>.

e.g.

    open my $fh, '<', __FILE__;
    my $string = do { local $/; <$fh> };
    my $tokens = Compiler::Lexer->new->tokenize($string);
    my $modules = $scanner->scan_tokens($tokens);

=item * add_extra_scanner($scanner_name)

Add extra scanner to scan and figure out prereqs. This module loads extra scanner such as C<Perl::PrereqScanner::Lite::Scanner::$scanner_name> if specifying scanner name through this method.

Extra scanners that are default supported are followings;

=over 8

=item * L<Perl::PrereqScanner::Lite::Scanner::Moose>

=item * L<Perl::PrereqScanner::Lite::Scanner::Version>

=back

=back

=head1 SEE ALSO

L<Perl::PrereqScanner>, L<Compiler::Lexer>

=head1 LICENSE

Copyright (C) moznion.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHOR

moznion E<lt>moznion@gmail.comE<gt>

=cut

