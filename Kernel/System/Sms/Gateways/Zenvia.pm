# --
# --

package Kernel::System::Sms::Gateways::Zenvia;

use strict;
use warnings;

use LWP;
use HTTP::Request;
use XML::Simple;
use Encode;

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
        $url.="account=$Gateway{account}&code=$Gateway{code}&from=$Gateway{from}&";
        $url.="dispatch=$Gateway{dispatch}&to=$Recipient{Email}&msg=$Sms{Body}";
        
        # Send the sms
        my $ua = LWP::UserAgent->new();
        my $req = new HTTP::Request GET => encode("ISO-8859-1",$url);
        my $res = $ua->request($req);
        
        if ($res->content ne "000 - Message Sent") {
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
