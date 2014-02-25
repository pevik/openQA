# Copyright (C) 2014 SUSE Linux Products GmbH
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

package OpenQA::CSRF;

use strict;
use warnings;

use base 'Mojolicious::Plugin';

use Scalar::Util ();
use Carp ();

sub register {

    my ($self, $app, $config) = @_;

    # replace form_for with our own that puts the csrf token in
    # there
    my $form_for = delete $app->renderer->helpers->{form_for} or die "failed to find form_for";
    $app->helper(
        form_for => sub {
            my $self = shift;
            my $code = $_[-1];
            if ( defined $code && ref $code eq 'CODE' ) {
                $_[-1] = sub {
                    $self->csrf_field . $code->();
                };
            }
            return $self->$form_for(@_);
        });

    # special anchor tag with data-method="post" and csrf token
    $app->helper(
        link_post => sub {
            my ($self, $content) = (shift, shift);
            my $url = $content;

            # Content
            unless (ref $_[-1] eq 'CODE') {
                $url = shift;
                push @_, $content;
            }

            Carp::croak "url is not a url"
                unless Scalar::Util::blessed $url && $url->isa('Mojo::URL');

            return $self->tag('a', href => $url->query(csrf_token => $self->csrf_token), 'data-method' => 'post', @_);
        });

    # require CSRF token for all requests that are not GET or HEAD
    $app->hook(
        before_routes => sub {
            my $c = shift;

            if ($c->req->method ne 'GET' && $c->req->method ne 'HEAD') {
                my $validation = $c->validation;
                if ($validation->csrf_protect->has_error('csrf_token')) {
                    $c->app->log->debug("Bad CSRF token");
                    return $c->render(text => 'Bad CSRF token!', status => 403)
                }
            }

            return 1;
        });
}

1;
