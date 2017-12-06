# --
# --

package Kernel::System::Sms::Gateways::MobilePronto;

use strict;
use warnings;

use LWP;
use HTTP::Request;
use XML::Simple;

use vars qw(@ISA $VERSION);
$VERSION = qw($Revision: 1.39.2.3 $) [1];

# disable redefine warnings in this scope
{
    no warnings 'redefine';

    # 
    # overwrite sub _TicketGetFirstResponse to get correct time and not only for escalated tickets
    sub Kernel::System::SmsEvent::SendSms {
        my ( $Self, %Param ) = @_;

        # get sms data
        my %Gateway = %{ $Param{Gateway} };
        my %Sms = %{ $Param{Sms} };
        my %Recipient = %{ $Param{Recipient} };

        # Clean MobileNumber
        my @S = ($Recipient{Email} =~ m/(\d+)/g);
        $Recipient{Email}=join("", @S);

        # Contruct the url
        my $url=$Gateway{URL}."?";
        $url.="CREDENCIAL=$Gateway{CREDENCIAL}&PRINCIPAL_USER=$Gateway{PRINCIPAL_USER}&";
        $url.="AUX_USER=$Gateway{AUX_USER}&MOBILE=$Recipient{Email}&SEND_PROJECT=$Gateway{SEND_PROJECT}&MESSAGE=$Sms{Body}";
        
        # Send the sms
        my $ua = LWP::UserAgent->new();
        my $req = new HTTP::Request GET => $url;
        my $res = $ua->request($req);
        
        if ($res->content ne "000") {
            $Self->{LogObject}->Log(
                 Priority => 'notice',
                 Message  => "Error on sending sms. Code: ".$res->content,
            );
            return 0;
        } else {
            return 1;
        }
    }
}

1;
