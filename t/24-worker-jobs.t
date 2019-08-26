#! /usr/bin/perl

# Copyright (C) 2019 SUSE LLC
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

use Mojo::Base -strict;

use FindBin;
use lib "$FindBin::Bin/lib";

use Test::More;
use Test::Fatal;
use Test::Output 'combined_like';
use Test::MockModule;
use Mojo::File qw(path tempdir);
use Mojo::UserAgent;
use Mojo::URL;
use Mojo::IOLoop;
use OpenQA::Worker::Job;
use OpenQA::Worker::Settings;
use OpenQA::Test::FakeWebSocketTransaction;

sub wait_until_job_status {
    my ($job, $status) = @_;

    # Do not wait forever in case of problems
    my $error;
    my $timer = Mojo::IOLoop->timer(
        15 => sub {
            $error = 'Job was not stopped after 15 seconds';
            Mojo::IOLoop->stop;
        });

    # Watch the status event for changes
    my $cb = $job->on(
        status_changed => sub {
            my ($job, $event_data) = @_;
            my $new = $event_data->{status};
            note "worker status change: $new";
            Mojo::IOLoop->stop if $new eq $status;
        });
    Mojo::IOLoop->start;
    $job->unsubscribe(status_changed => $cb);
    Mojo::IOLoop->remove($timer);

    return $error;
}

# Fake worker, client and engine
{
    package Test::FakeWorker;
    use Mojo::Base -base;
    has instance_number => 1;
    has settings        => sub { OpenQA::Worker::Settings->new(1, {}) };
    has pool_directory  => undef;
}
{
    package Test::FakeClient;
    use Mojo::Base -base;
    has worker_id            => 1;
    has webui_host           => 'not relevant here';
    has working_directory    => 'not relevant here';
    has testpool_server      => 'not relevant here';
    has sent_messages        => sub { [] };
    has websocket_connection => sub { OpenQA::Test::FakeWebSocketTransaction->new };
    has ua                   => sub { Mojo::UserAgent->new };
    has url                  => sub { Mojo::URL->new };
    has register_called      => 0;
    sub send {
        my ($self, $method, $path, %args) = @_;
        push(@{shift->sent_messages}, {path => $path, json => $args{json}});
        Mojo::IOLoop->next_tick(sub { $args{callback}->({}) }) if $args{callback};
    }
    sub send_status { push(@{shift->sent_messages}, @_) }
    sub register { shift->register_called(1) }
}
{
    package Test::FakeEngine;
    use Mojo::Base -base;
    has pid        => 1;
    has errored    => 0;
    has is_running => 1;
    sub stop { shift->is_running(0) }
}

my $isotovideo     = Test::FakeEngine->new;
my $worker         = Test::FakeWorker->new;
my $pool_directory = tempdir('poolXXXX');
$worker->pool_directory($pool_directory);
my $client = Test::FakeClient->new;
$client->ua->connect_timeout(0.1);
my $engine_url = '127.0.0.1:' . Mojo::IOLoop::Server->generate_port;

# Mock isotovideo engine (simulate startup failure)
my $engine_mock = Test::MockModule->new('OpenQA::Worker::Engines::isotovideo');
$engine_mock->mock(
    engine_workit => sub {
        note 'pretending isotovideo startup error';
        return {error => 'this is not a real isotovideo'};
    });

# Mock isotovideo REST API
my $api_mock = Test::MockModule->new('OpenQA::Worker::Isotovideo::Client');
$api_mock->mock(
    status => sub {
        my ($isotovideo_client, $callback) = @_;
        Mojo::IOLoop->next_tick(sub { $callback->($isotovideo_client, {}) });
    });

subtest 'Interrupted WebSocket connection' => sub {
    is_deeply $client->websocket_connection->sent_messages, [], 'no WebSocket calls yet';
    my $job = OpenQA::Worker::Job->new($worker, $client, {id => 1, URL => $engine_url});
    $job->accept;
    is $job->status, 'accepted', 'job is now accepted';
    $job->client->websocket_connection->emit_finish;
    is $job->status, 'accepted',
      'ws disconnects are not considered fatal one the job is accepted so it is still in accepted state';

    is_deeply(
        $client->websocket_connection->sent_messages,
        [
            {
                json => {
                    jobid => 1,
                    type  => 'accepted',
                }}
        ],
        'job accepted via WebSocket'
    ) or diag explain $client->websocket_connection->sent_messages;
    $client->websocket_connection->sent_messages([]);
};

subtest 'Interrupted WebSocket connection (before we can tell the WebUI that we want to work on it)' => sub {
    is_deeply $client->websocket_connection->sent_messages, [], 'no WebSocket calls yet';

    my $job = OpenQA::Worker::Job->new($worker, $client, {id => 2, URL => $engine_url});
    $job->accept;
    is $job->status, 'accepted', 'job is now accepted';
    $job->_set_status(accepting => {});
    $job->client->websocket_connection->emit_finish;
    is $job->status, 'stopped', 'job is abandoned if unable to confirm to the web UI that we are working on it';
    like(
        exception { $job->start },
        qr/attempt to start job which is not accepted/,
        'starting job prevented unless accepted'
    );

    is_deeply(
        $client->websocket_connection->sent_messages,
        [
            {
                json => {
                    jobid => 2,
                    type  => 'accepted',
                }}
        ],
        'job accepted via WebSocket'
    ) or diag explain $client->websocket_connection->sent_messages;
    $client->websocket_connection->sent_messages([]);
};

subtest 'Job without id' => sub {
    my $job = OpenQA::Worker::Job->new($worker, $client, {id => undef, URL => $engine_url});
    like(
        exception { $job->start },
        qr/attempt to start job without ID and job info/,
        'starting job without id prevented'
    );
};

subtest 'Clean up pool directory' => sub {
    is_deeply $client->websocket_connection->sent_messages, [], 'no WebSocket calls yet';
    is_deeply $client->sent_messages,                       [], 'no REST-API calls yet';

    my $job = OpenQA::Worker::Job->new($worker, $client, {id => 3, URL => $engine_url});
    $job->accept;
    is $job->status, 'accepted', 'job is now accepted';

    # Put some 'old' logs into the pool directory to verify whether those are cleaned up
    $pool_directory->child('autoinst-log.txt')->spurt('Hello Mojo!');

    # Put a fake test_order.json into the pool directory
    my $testresults_directory = path($pool_directory, 'testresults');
    $testresults_directory->make_path;
    $testresults_directory->child('test_order.json')->spurt('[]');

    # Try to start job
    combined_like sub { $job->start }, qr/Unable to setup job 3: this is not a real isotovideo/, 'error logged';
    is wait_until_job_status($job, 'stopped'), undef, 'no error';
    is $job->status, 'stopped', 'job is stopped due to the mocked error';
    is $job->setup_error, 'this is not a real isotovideo', 'setup error recorded';

    # verify old logs being cleaned up and worker-log.txt being created
    ok !-e $pool_directory->child('autoinst-log.txt'), 'autoinst-log.txt file has been deleted';
    ok -e $pool_directory->child('worker-log.txt'),    'worker log is there';

    is_deeply(
        $client->sent_messages,
        [
            {
                json => {
                    status => {
                        uploading => 1,
                        worker_id => 1
                    }
                },
                path => 'jobs/3/status'
            },
            {
                json => {
                    status => {
                        backend               => undef,
                        cmd_srv_url           => $engine_url,
                        result                => {},
                        test_execution_paused => 0,
                        test_order            => [],
                        worker_hostname       => undef,
                        worker_id             => 1
                    }
                },
                path => 'jobs/3/status'
            },
            {
                json => undef,
                path => 'jobs/3/set_done'
            }
        ],
        'expected REST-API calls happened'
    ) or diag explain $client->sent_messages;
    $client->sent_messages([]);

    is_deeply(
        $client->websocket_connection->sent_messages,
        [
            {
                json => {
                    jobid => 3,
                    type  => 'accepted',
                }}
        ],
        'job accepted via WebSocket'
    ) or diag explain $client->websocket_connection->sent_messages;
    $client->websocket_connection->sent_messages([]);
};

# Mock isotovideo engine (simulate successful startup and stop)
$engine_mock->mock(
    engine_workit => sub {
        my $job = shift;
        note 'pretending to run isotovideo';
        $job->once(
            uploading_results_concluded => sub {
                note "pretending job @{[$job->id]} is done";
                $job->stop('done');
            });
        return {child => $isotovideo->is_running(1)};
    });

subtest 'Successful job' => sub {
    is_deeply $client->websocket_connection->sent_messages, [], 'no WebSocket calls yet';
    is_deeply $client->sent_messages,                       [], 'no REST-API calls yet';

    my $job = OpenQA::Worker::Job->new($worker, $client, {id => 4, URL => $engine_url});
    $job->accept;
    is $job->status, 'accepted', 'job is now accepted';
    combined_like(sub { $job->start }, qr/isotovideo has been started/, 'isotovideo startup logged');

    my ($status, $is_uploading_results);
    $job->once(
        uploading_results_concluded => sub {
            my $job = shift;
            $is_uploading_results = $job->is_uploading_results;
            $status               = $job->status;
        });
    is wait_until_job_status($job, 'stopped'), undef, 'no error';
    is $is_uploading_results, 0,          'uploading results concluded';
    is $status,               'stopping', 'job is stopping now';

    is $job->status,               'stopped', 'job is stopped successfully';
    is $job->is_uploading_results, 0,         'uploading results concluded';

    is_deeply(
        $client->sent_messages,
        [
            {
                json => {
                    status => {
                        cmd_srv_url           => $engine_url,
                        test_execution_paused => 0,
                        worker_hostname       => undef,
                        worker_id             => 1
                    }
                },
                "path" => 'jobs/4/status'
            },
            {
                json => {
                    status => {
                        uploading => 1,
                        worker_id => 1
                    }
                },
                path => 'jobs/4/status'
            },
            {
                json => {
                    status => {
                        backend               => undef,
                        cmd_srv_url           => $engine_url,
                        result                => {},
                        test_execution_paused => 0,
                        test_order            => [],
                        worker_hostname       => undef,
                        worker_id             => 1
                    }
                },
                path => 'jobs/4/status'
            },
            {
                json => undef,
                path => 'jobs/4/set_done'
            }
        ],
        'expected REST-API calls happened'
    ) or diag explain $client->sent_messages;
    $client->sent_messages([]);

    is_deeply(
        $client->websocket_connection->sent_messages,
        [
            {
                json => {
                    jobid => 4,
                    type  => 'accepted',
                }}
        ],
        'job accepted via WebSocket'
    ) or diag explain $client->websocket_connection->sent_messages;
    $client->websocket_connection->sent_messages([]);
};

subtest 'Livelog' => sub {
    is_deeply $client->websocket_connection->sent_messages, [], 'no WebSocket calls yet';
    is_deeply $client->sent_messages,                       [], 'no REST-API calls yet';

    my $job = OpenQA::Worker::Job->new($worker, $client, {id => 5, URL => $engine_url});
    my @status;
    $job->on(
        status_changed => sub {
            my ($job, $event_data) = @_;
            push @status, $event_data->{status};
        });
    $job->accept;
    is $job->status, 'accepted', 'job is now accepted';
    combined_like(sub { $job->start }, qr/isotovideo has been started/, 'isotovideo startup logged');

    $job->developer_session_running(1);
    combined_like(sub { $job->start_livelog }, qr/Starting livelog/, 'start of livelog logged');
    is $job->livelog_viewers, 1, 'has now one livelog viewer';
    $job->once(
        uploading_results_concluded => sub {
            my $job = shift;
            combined_like(sub { $job->stop_livelog }, qr/Stopping livelog/, 'stopping of livelog logged');
        });
    is wait_until_job_status($job, 'stopped'), undef, 'no error';
    is $job->livelog_viewers, 0, 'no livelog viewers anymore';

    is $job->status,               'stopped', 'job is stopped successfully';
    is $job->is_uploading_results, 0,         'uploading results concluded';

    is_deeply \@status, [qw(accepting accepted setup running stopping stopped)], 'expected status changes';

    is_deeply(
        $client->sent_messages,
        [
            {
                json => {
                    status => {
                        cmd_srv_url           => $engine_url,
                        log                   => {},
                        serial_log            => {},
                        serial_terminal       => {},
                        test_execution_paused => 0,
                        worker_hostname       => undef,
                        worker_id             => 1
                    }
                },
                path => 'jobs/5/status'
            },
            {
                json => {
                    status => {
                        cmd_srv_url           => $engine_url,
                        log                   => {},
                        serial_log            => {},
                        serial_terminal       => {},
                        test_execution_paused => 0,
                        worker_hostname       => undef,
                        worker_id             => 1
                    }
                },
                path => 'jobs/5/status'
            },
            {
                json => {
                    outstanding_files           => 0,
                    outstanding_images          => 0,
                    upload_up_to                => undef,
                    upload_up_to_current_module => undef
                },
                path => '/liveviewhandler/api/v1/jobs/5/upload_progress'
            },
            {
                json => {
                    status => {
                        uploading => 1,
                        worker_id => 1
                    }
                },
                path => 'jobs/5/status'
            },
            {
                json => {
                    status => {
                        backend               => undef,
                        cmd_srv_url           => $engine_url,
                        result                => {},
                        test_execution_paused => 0,
                        test_order            => [],
                        worker_hostname       => undef,
                        worker_id             => 1
                    }
                },
                path => 'jobs/5/status'
            },
            {
                json => undef,
                path => 'jobs/5/set_done'
            }
        ],
        'expected REST-API calls happened'
    ) or diag explain $client->sent_messages;
    $client->sent_messages([]);

    is_deeply(
        $client->websocket_connection->sent_messages,
        [
            {
                json => {
                    jobid => 5,
                    type  => 'accepted',
                }}
        ],
        'job accepted via WebSocket'
    ) or diag explain $client->websocket_connection->sent_messages;
    $client->websocket_connection->sent_messages([]);
};

done_testing();
