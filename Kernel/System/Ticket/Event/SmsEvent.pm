# --
# Kernel/System/Ticket/Event/SmsEvent.pm - a event module to send smss
# Copyright (C) 2001-2013 OTRS AG, http://otrs.org/
# --
# $Id: SmsEvent.pm,v 1.48 2013/01/14 18:30:02 cr Exp $
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (AGPL). If you
# did not receive this file, see http://www.gnu.org/licenses/agpl.txt.
# --

package Kernel::System::Ticket::Event::SmsEvent;

use strict;
use warnings;

use Kernel::System::SmsEvent;
use Kernel::System::SystemAddress;
use Kernel::System::DynamicField;
use Kernel::System::DynamicField::Backend;
use Kernel::System::VariableCheck qw(:all);

use vars qw($VERSION);
$VERSION = qw($Revision: 1.48 $) [1];

sub new {
    my ( $Type, %Param ) = @_;

    # allocate new hash for object
    my $Self = {};
    bless( $Self, $Type );

    # get needed objects
    for my $Needed (
        qw(
        DBObject ConfigObject TicketObject LogObject TimeObject UserObject CustomerUserObject
        SendmailObject QueueObject GroupObject MainObject EncodeObject
        )
        )
    {
        $Self->{$Needed} = $Param{$Needed} || die "Got no $Needed!";
    }

    $Self->{DynamicFieldObject} = Kernel::System::DynamicField->new(%Param);
    $Self->{BackendObject}      = Kernel::System::DynamicField::Backend->new(%Param);

    # get dynamic fields
    $Self->{DynamicField} = $Self->{DynamicFieldObject}->DynamicFieldListGet(
        Valid      => 1,
        ObjectType => ['Ticket'],
    );

    # create a dynamic field config lookup table
    for my $DynamicFieldConfig ( @{ $Self->{DynamicField} } ) {
        $Self->{DynamicFieldConfigLookup}->{ $DynamicFieldConfig->{Name} } = $DynamicFieldConfig;
    }

    return $Self;
}

sub Run {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    for (qw(Event Data Config UserID)) {
        if ( !$Param{$_} ) {
            $Self->{LogObject}->Log( Priority => 'error', Message => "Need $_!" );
            return;
        }
    }
    for (qw(TicketID)) {
        if ( !$Param{Data}->{$_} ) {
            $Self->{LogObject}->Log( Priority => 'error', Message => "Need $_ in Data!" );
            return;
        }
    }

    # return if no sms is active
    return 1 if $Self->{TicketObject}->{SendNoSms};

    # return if no ticket exists (e. g. it got deleted)
    my $TicketExists = $Self->{TicketObject}->TicketNumberLookup(
        TicketID => $Param{Data}->{TicketID},
        UserID   => $Param{UserID},
    );
    return 1 if !$TicketExists;

    # check if event is affected
    my $SmsEventObject = Kernel::System::SmsEvent->new( %{$Self} );
    my @IDs = $SmsEventObject->SmsEventCheck(
        Event  => $Param{Event},
        UserID => $Param{UserID},
    );

    # return if no sms for event exists
    return 1 if !@IDs;

    # get ticket attribute matches
    my %Ticket = $Self->{TicketObject}->TicketGet(
        TicketID      => $Param{Data}->{TicketID},
        UserID        => $Param{UserID},
        DynamicFields => 1,
    );

    NOTIFICATION:
    for my $ID (@IDs) {
        my %Sms = $SmsEventObject->SmsGet(
            ID     => $ID,
            UserID => 1,
        );
        next NOTIFICATION if !$Sms{Data};
        for my $Key ( sort keys %{ $Sms{Data} } ) {

            # ignore not ticket related attributes
            next if $Key eq 'Recipients';
            next if $Key eq 'RecipientAgents';
            next if $Key eq 'RecipientGroups';
            next if $Key eq 'RecipientRoles';
            next if $Key eq 'RecipientEmail';
            next if $Key eq 'Events';
            next if $Key eq 'ArticleTypeID';
            next if $Key eq 'ArticleSenderTypeID';
            next if $Key eq 'ArticleSubjectMatch';
            next if $Key eq 'ArticleBodyMatch';
            next if $Key eq 'Gateway';
            next if $Key eq 'SmsArticleTypeID';

            # check ticket attributes
            next if !$Sms{Data}->{$Key};
            next if !@{ $Sms{Data}->{$Key} };
            next if !$Sms{Data}->{$Key}->[0];
            my $Match = 0;
            VALUE:
            for my $Value ( @{ $Sms{Data}->{$Key} } ) {
                next VALUE if !$Value;

                # check if key is a search dynamic field
                if ( $Key =~ m{\A Search_DynamicField_}xms ) {

                    # remove search prefix
                    my $DynamicFieldName = $Key;

                    $DynamicFieldName =~ s{Search_DynamicField_}{};

                    # get the dynamic field config for this field
                    my $DynamicFieldConfig = $Self->{DynamicFieldConfigLookup}->{$DynamicFieldName};

                    next if !$DynamicFieldConfig;

                    $Match = $Self->{BackendObject}->ObjectMatch(
                        DynamicFieldConfig => $DynamicFieldConfig,
                        Value              => $Value,
                        ObjectAttributes   => \%Ticket,
                    );
                    last if $Match;
                }
                else {

                    if ( $Value eq $Ticket{$Key} ) {
                        $Match = 1;
                        last;
                    }
                }
            }
            next NOTIFICATION if !$Match;
        }
                   
        # match article types only on ArticleCreate event
        my @Attachments;
        if ( $Param{Event} eq 'ArticleCreate' && $Param{Data}->{ArticleID} ) {
            my %Article = $Self->{TicketObject}->ArticleGet(
                ArticleID     => $Param{Data}->{ArticleID},
                UserID        => $Param{UserID},
                DynamicFields => 0,
            );

            # check article type
            if ( $Sms{Data}->{ArticleTypeID} ) {
                my $Match = 0;
                VALUE:
                for my $Value ( @{ $Sms{Data}->{ArticleTypeID} } ) {
                    next VALUE if !$Value;
                    if ( $Value == $Article{ArticleTypeID} ) {
                        $Match = 1;
                        last;
                    }
                }
                next NOTIFICATION if !$Match;
            }

            # check article sender type
            if ( $Sms{Data}->{ArticleSenderTypeID} ) {
                my $Match = 0;
                VALUE:
                for my $Value ( @{ $Sms{Data}->{ArticleSenderTypeID} } ) {
                    next VALUE if !$Value;
                    if ( $Value == $Article{SenderTypeID} ) {
                        $Match = 1;
                        last;
                    }
                }
                next NOTIFICATION if !$Match;
            }

            # check subject & body
            for my $Key (qw( Subject Body )) {
                next if !$Sms{Data}->{ 'Article' . $Key . 'Match' };
                my $Match = 0;
                VALUE:
                for my $Value ( @{ $Sms{Data}->{ 'Article' . $Key . 'Match' } } ) {
                    next VALUE if !$Value;
                    if ( $Article{$Key} =~ /\Q$Value\E/i ) {
                        $Match = 1;
                        last;
                    }
                }
                next NOTIFICATION if !$Match;
            }

            # add attachments to sms
#            if ( $Sms{Data}->{Gateway}->[0] ) {
#                my %Index = $Self->{TicketObject}->ArticleAttachmentIndex(
#                    ArticleID                  => $Param{Data}->{ArticleID},
#                    UserID                     => $Param{UserID},
#                    StripPlainBodyAsAttachment => 3,
#                );
#                if (%Index) {
#                    for my $FileID ( sort keys %Index ) {
#                        my %Attachment = $Self->{TicketObject}->ArticleAttachment(
#                            ArticleID => $Param{Data}->{ArticleID},
#                            FileID    => $FileID,
#                            UserID    => $Param{UserID},
#                        );
#                        next if !%Attachment;
#                        push @Attachments, \%Attachment;
#                    }
#                }
#            }
        }


        # send sms
        $Self->_SendSmsToRecipients(
            TicketID              => $Param{Data}->{TicketID},
            UserID                => $Param{UserID},
            Sms                   => \%Sms,
            CustomerMessageParams => {},
            Event                 => $Param{Event},
            Attachments           => \@Attachments,
        );
    }

    return 1;
}

# Assemble the list of recipients. Agents and customer users can be recipient.
# Call _SendSms() for each recipient.
sub _SendSmsToRecipients {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    for (qw(CustomerMessageParams TicketID UserID Sms)) {
        if ( !$Param{$_} ) {
            $Self->{LogObject}->Log( Priority => 'error', Message => "Need $_!" );
            return;
        }
    }

    # get old article for quoting
    my %Article = $Self->{TicketObject}->ArticleLastCustomerArticle(
        TicketID      => $Param{TicketID},
        DynamicFields => 0,
    );

    # get recipients by Recipients
    my @Recipients;
    if ( $Param{Sms}->{Data}->{Recipients} ) {
        RECIPIENT:
        for my $Recipient ( @{ $Param{Sms}->{Data}->{Recipients} } ) {
            if ( $Recipient =~ /^Agent(Owner|Responsible|WritePermissions)$/ ) {
                if ( $Recipient eq 'AgentOwner' ) {
                    push @{ $Param{Sms}->{Data}->{RecipientAgents} }, $Article{OwnerID};
                }
                elsif ( $Recipient eq 'AgentResponsible' ) {
                    push @{ $Param{Sms}->{Data}->{RecipientAgents} },
                        $Article{ResponsibleID};
                }
                elsif ( $Recipient eq 'AgentWritePermissions' ) {
                    my $GroupID = $Self->{QueueObject}->GetQueueGroupID(
                        QueueID => $Article{QueueID},
                    );
                    my @UserIDs = $Self->{GroupObject}->GroupMemberList(
                        GroupID => $GroupID,
                        Type    => 'rw',
                        Result  => 'ID',
                    );
                    push @{ $Param{Sms}->{Data}->{RecipientAgents} }, @UserIDs;
                }
            }
            elsif ( $Recipient eq 'Customer' ) {
                my %Recipient;

                # ArticleLastCustomerArticle() returns the lastest customer article but if there
                # is no customer acticle, it returns the latest agent article. In this case
                # sms must not be send to the "From", but to the "To" article field.
                if ( $Article{SenderType} eq 'customer' ) {
                    $Recipient{Email} = $Article{From};
                }
                else {
                    $Recipient{Email} = $Article{To};
                }
                $Recipient{Type} = 'Customer';

                # check if customer smss should be send
                # COMPLEMENTO: SMS different from mail notification, should only be sent if this customer has an account in the system
                if ( !$Article{CustomerUserID}  )
                {
                    $Self->{LogObject}->Log(
                        Priority => 'notice',
                        Message  => 'Send no customer sms because no customer is set!',
                    );
                    next RECIPIENT;
                }

                # check customer Mobile
                else {
                    my %CustomerUser = $Self->{CustomerUserObject}->CustomerUserDataGet(
                        User => $Article{CustomerUserID},
                    );
                    if ( !$CustomerUser{UserMobile} ) {
                        $Self->{LogObject}->Log(
                            Priority => 'notice',
                            Message  => "Send no customer sms because of missing "
                                . "customer Mobile Number (CustomerUserID=$CustomerUser{CustomerUserID})!",
                        );
                        next RECIPIENT;
                    }
                }

                # get language and send recipient
                $Recipient{Language} = $Self->{ConfigObject}->Get('DefaultLanguage') || 'en';
                if ( $Article{CustomerUserID} ) {
                    my %CustomerUser = $Self->{CustomerUserObject}->CustomerUserDataGet(
                        User => $Article{CustomerUserID},
                    );
                    if ( $CustomerUser{UserMobile} ) {
                            # COMPLEMENTO: change UserEmail to UserMobile
#                        $Recipient{Email} = $CustomerUser{UserEmail};
                        $Recipient{Email} = $CustomerUser{UserMobile};
                    }

                    # get user language
                    if ( $CustomerUser{UserLanguage} ) {
                        $Recipient{Language} = $CustomerUser{UserLanguage};
                    }
                }

                # check recipients
                # COMPLEMENTO: we disable the "at" verification since it's a phone number and not an email
#                if ( !$Recipient{Email} || $Recipient{Email} !~ /@/ ) {
                if ( !$Recipient{Email} ) {
                    next RECIPIENT;
                }

                # get realname
                if ( $Article{CustomerUserID} ) {
                    $Recipient{Realname} = $Self->{CustomerUserObject}->CustomerName(
                        UserLogin => $Article{CustomerUserID},
                    );
                }
                if ( !$Recipient{Realname} ) {
                    $Recipient{Realname} = $Article{From} || '';
                    $Recipient{Realname} =~ s/<.*>|\(.*\)|\"|;|,//g;
                    $Recipient{Realname} =~ s/( $)|(  $)//g;
                }

                push @Recipients, \%Recipient;
            }
        }
    }

    # hash to keep track which agents are already receiving this sms
    my %AgentUsed;

    # get recipients by RecipientAgents
    if ( $Param{Sms}->{Data}->{RecipientAgents} ) {
        RECIPIENT:
        for my $Recipient ( @{ $Param{Sms}->{Data}->{RecipientAgents} } ) {
            
            next if $Recipient == 1;
            next if $AgentUsed{$Recipient};
            $AgentUsed{$Recipient} = 1;

            my %User = $Self->{UserObject}->GetUserData(
                UserID => $Recipient,
                Valid  => 1,
            );
            next RECIPIENT if !%User;
            next RECIPIENT if !$User{UserLogin};

            my %CustomerUser = $Self->{CustomerUserObject}->CustomerUserDataGet(
                User => $User{UserLogin},
            );

            next RECIPIENT if !%CustomerUser;
            next RECIPIENT if !$CustomerUser{UserMobile};

            my %Recipient;

            $Recipient{Email} = $CustomerUser{UserMobile};
            $Recipient{Type}  = 'Agent';


            push @Recipients, \%Recipient;
        }
    }

    # get recipients by RecipientGroups
    if ( $Param{Sms}->{Data}->{RecipientGroups} ) {
        RECIPIENT:
        for my $Group ( @{ $Param{Sms}->{Data}->{RecipientGroups} } ) {
            my @GroupMemberList = $Self->{GroupObject}->GroupMemberList(
                Result  => 'ID',
                Type    => 'ro',
                GroupID => $Group,
            );
            GROUPMEMBER:
            for my $Recipient (@GroupMemberList) {
                next GROUPMEMBER if $Recipient == 1;
                next GROUPMEMBER if $AgentUsed{$Recipient};
                $AgentUsed{$Recipient} = 1;
                my %UserData = $Self->{UserObject}->GetUserData(
                    UserID => $Recipient,
                    Valid  => 1
                );
                next GROUPMEMBER if !%UserData;
                next GROUPMEMBER if !$UserData{UserLogin};

                my %CustomerUser = $Self->{CustomerUserObject}->CustomerUserDataGet(
                    User => $UserData{UserLogin},
                );

                next GROUPMEMBER if !%CustomerUser;
                next GROUPMEMBER if !$CustomerUser{UserMobile};

                if ( $UserData{UserMobile} ) {
                    my %Recipient;
                    $Recipient{Email} = $UserData{UserMobile};
                    $Recipient{Type}  = 'Agent';
                    push @Recipients, \%Recipient;
                }
            }
        }
    }

    # get recipients by RecipientRoles
    if ( $Param{Sms}->{Data}->{RecipientRoles} ) {
        RECIPIENT:
        for my $Role ( @{ $Param{Sms}->{Data}->{RecipientRoles} } ) {
            my @RoleMemberList = $Self->{GroupObject}->GroupUserRoleMemberList(
                Result => 'ID',
                RoleID => $Role,
            );
            ROLEMEMBER:
            for my $Recipient (@RoleMemberList) {
                next ROLEMEMBER if $Recipient == 1;
                next ROLEMEMBER if $AgentUsed{$Recipient};
                $AgentUsed{$Recipient} = 1;
                my %UserData = $Self->{UserObject}->GetUserData(
                    UserID => $Recipient,
                    Valid  => 1
                );
                
                next ROLEMEMBER if !%UserData;
                next ROLEMEMBER if !$UserData{UserLogin};

                my %CustomerUser = $Self->{CustomerUserObject}->CustomerUserDataGet(
                    User => $UserData{UserLogin},
                );

                next ROLEMEMBER if !%CustomerUser;
                next ROLEMEMBER if !$CustomerUser{UserMobile};
                
                if ( $UserData{UserMobile} ) {
                    my %Recipient;
                    $Recipient{Email} = $UserData{UserMobile};
                    $Recipient{Type}  = 'Agent';
                    push @Recipients, \%Recipient;
                }
            }
        }
    }

    # get recipients by RecipientEmail
    if ( $Param{Sms}->{Data}->{RecipientEmail} ) {
        if ( $Param{Sms}->{Data}->{RecipientEmail}->[0] ) {
           
            # COMPLEMENTO: split numbers by comma and ;
            my @numbers = split /[,;]/,$Param{Sms}->{Data}->{RecipientEmail}->[0];

            for my $number (@numbers){
                my %Recipient;  
    
                $Recipient{Realname} = '';
                $Recipient{Type}     = 'Customer';
                $Recipient{Email}    = $number;

                # check if we have a specified article type
                if ( $Param{Sms}->{Data}->{SmsArticleTypeID} ) {
                    $Recipient{SmsArticleType} = $Self->{TicketObject}->ArticleTypeLookup(
                        ArticleTypeID => $Param{Sms}->{Data}->{SmsArticleTypeID}->[0]
                    ) || 'sms';
                }

                # check recipients
                # COMPLEMENTO: dont check "At"
    #            if ( $Recipient{Email} && $Recipient{Email} =~ /@/ ) {
                if ( $Recipient{Email} ) {
                    push @Recipients, \%Recipient;
                }
            }
        }
    }

    # Get current user data
    my %CurrentUser = $Self->{UserObject}->GetUserData(
        UserID => $Param{UserID},
    );
    $Self->{SystemAddressObject} = Kernel::System::SystemAddress->new( %{$Self} );
    RECIPIENT:
    for my $Recipient (@Recipients) {
#        if (
#            $Self->{SystemAddressObject}->SystemAddressIsLocalAddress(
#                Address => $Recipient->{Email}
#            )
#            )
#        {
#            next RECIPIENT;
#        }

        # do not send email to self if AgentSelfSms is set to No
        # COMPLEMENTO @TODO: Don't notify self agent with sms
#        if (
#            !$Self->{ConfigObject}->Get('AgentSelfNotifyOnAction')
#            && $Recipient->{Email} eq $CurrentUser{UserEmail}
#            )
#        {
#            next RECIPIENT
#        }

        $Self->_SendSms(
            TicketID              => $Param{TicketID},
            UserID                => $Param{UserID},
            Sms                   => $Param{Sms},
            CustomerMessageParams => {},
            Recipient             => $Recipient,
            Event                 => $Param{Event},
            Attachments           => $Param{Attachments},
        );
    }
    return 1;
}

# send sms to
sub _SendSms {
    my ( $Self, %Param ) = @_;

    # get sms data
    my %Sms = %{ $Param{Sms} };

    # get recipient data
    my %Recipient = %{ $Param{Recipient} };

    # get old article for quoting
    my %Article = $Self->{TicketObject}->ArticleLastCustomerArticle(
        TicketID      => $Param{TicketID},
        DynamicFields => 1,
    );

    # get sms texts
    for (qw(Body Subject)) {
        next if $Sms{$_};
        $Sms{$_} = "No CustomerSms $_ for $Param{Type} found!";
    }

    # replace config options
    $Sms{Body}    =~ s{<OTRS_CONFIG_(.+?)>}{$Self->{ConfigObject}->Get($1)}egx;
    $Sms{Subject} =~ s{<OTRS_CONFIG_(.+?)>}{$Self->{ConfigObject}->Get($1)}egx;

    # cleanup
    $Sms{Subject} =~ s/<OTRS_CONFIG_.+?>/-/gi;
    $Sms{Body}    =~ s/<OTRS_CONFIG_.+?>/-/gi;

    # COMPAT
    $Sms{Body} =~ s/<OTRS_TICKET_ID>/$Param{TicketID}/gi;
    $Sms{Body} =~ s/<OTRS_TICKET_NUMBER>/$Article{TicketNumber}/gi;

    # ticket data
    my %Ticket = $Self->{TicketObject}->TicketGet(
        TicketID      => $Param{TicketID},
        DynamicFields => 1,
    );

    # prepare customer realname
    if ( $Sms{Body} =~ /<OTRS_CUSTOMER_REALNAME>/ ) {
        my $RealName = $Self->{CustomerUserObject}->CustomerName(
            UserLogin => $Ticket{CustomerUserID}
        ) || $Recipient{Realname};
        $Sms{Body} =~ s/<OTRS_CUSTOMER_REALNAME>/$RealName/g;
    }

    for my $Key ( sort keys %Ticket ) {
        next if !defined $Ticket{$Key};

        my $DisplayKeyValue = $Ticket{$Key};
        my $DisplayValue    = $Ticket{$Key};
    
        # COMPLEMENTO: Verify system version and the correct code for that
        if ( $Key =~ /^DynamicField_/i && $Self->{ConfigObject}->{Version} =~ m/^3\.2/) {

            my $FieldName = $Key;
            $FieldName =~ s/DynamicField_//gi;

            # get dynamic field config
            my $DynamicField = $Self->{TicketObject}->{DynamicFieldObject}->DynamicFieldGet(
                Name => $FieldName,
            );

            # get the display value for each dynamic field
            $DisplayValue = $Self->{BackendObject}->ValueLookup(
                DynamicFieldConfig => $DynamicField,
                Key                => $Ticket{$Key},
            );

            # get the readable value (value) for each dynamic field
            my $ValueStrg = $Self->{BackendObject}->ReadableValueRender(
                DynamicFieldConfig => $DynamicField,
                Value              => $DisplayValue,
            );
            $DisplayValue = $ValueStrg->{Value};

            # get display key value
            my $KeyValueStrg
                = $Self->{TicketObject}->{DynamicFieldBackendObject}->ReadableValueRender(
                DynamicFieldConfig => $DynamicField,
                Value              => $DisplayKeyValue,
                );
            $DisplayKeyValue = $KeyValueStrg->{Value};
        } elsif ( $Key =~ /^DynamicField_/i && $Self->{ConfigObject}->{Version} =~ m/^3\.1/) {

            my $FieldName = $Key;
            $FieldName =~ s/DynamicField_//gi;

            # get dynamic field config
            my $DynamicField = $Self->{TicketObject}->{DynamicFieldObject}->DynamicFieldGet(
                Name => $FieldName,
            );

            # get display value
            my $ValueStrg = $Self->{TicketObject}->{DynamicFieldBackendObject}->ReadableValueRender(
                DynamicFieldConfig => $DynamicField,
                Value              => $DisplayValue,
            );
            $DisplayValue = $ValueStrg->{Value};
        }


        $Sms{Body}    =~ s/<OTRS_TICKET_$Key>/$DisplayKeyValue/gi;
        $Sms{Subject} =~ s/<OTRS_TICKET_$Key>/$DisplayKeyValue/gi;

        my $Tag = '<OTRS_TICKET_' . $Key . '_Value>';
        $Sms{Body}    =~ s/$Tag/$DisplayValue/gi;
        $Sms{Subject} =~ s/$Tag/$DisplayValue/gi;

    }


    # cleanup
    $Sms{Subject} =~ s/<OTRS_TICKET_.+?>/-/gi;
    $Sms{Body}    =~ s/<OTRS_TICKET_.+?>/-/gi;

    # get current user data
    my %CurrentPreferences = $Self->{UserObject}->GetUserData(
        UserID        => $Param{UserID},
        NoOutOfOffice => 1,
    );
    for ( sort keys %CurrentPreferences ) {
        next if !defined $CurrentPreferences{$_};
        $Sms{Body}    =~ s/<OTRS_CURRENT_$_>/$CurrentPreferences{$_}/gi;
        $Sms{Subject} =~ s/<OTRS_CURRENT_$_>/$CurrentPreferences{$_}/gi;
    }

    # cleanup
    $Sms{Subject} =~ s/<OTRS_CURRENT_.+?>/-/gi;
    $Sms{Body}    =~ s/<OTRS_CURRENT_.+?>/-/gi;

    # get owner data
    my $OwnerID = $Article{OwnerID};

    # get owner from ticket if there are no articles
    if ( !$OwnerID ) {
        $OwnerID = $Ticket{OwnerID};
    }
    my %OwnerPreferences = $Self->{UserObject}->GetUserData(
        UserID        => $OwnerID,
        NoOutOfOffice => 1,
    );
    for ( sort keys %OwnerPreferences ) {
        next if !$OwnerPreferences{$_};
        $Sms{Body}    =~ s/<OTRS_OWNER_$_>/$OwnerPreferences{$_}/gi;
        $Sms{Subject} =~ s/<OTRS_OWNER_$_>/$OwnerPreferences{$_}/gi;
    }

    # cleanup
    $Sms{Subject} =~ s/<OTRS_OWNER_.+?>/-/gi;
    $Sms{Body}    =~ s/<OTRS_OWNER_.+?>/-/gi;

    # get responsible data
    my $ResponsibleID = $Article{ResponsibleID};

    # get responsible from ticket if there are no articles
    if ( !$ResponsibleID ) {
        $ResponsibleID = $Ticket{ResponsibleID};
    }

    my %ResponsiblePreferences = $Self->{UserObject}->GetUserData(
        UserID        => $ResponsibleID,
        NoOutOfOffice => 1,
    );
    for ( sort keys %ResponsiblePreferences ) {
        next if !$ResponsiblePreferences{$_};
        $Sms{Body}    =~ s/<OTRS_RESPONSIBLE_$_>/$ResponsiblePreferences{$_}/gi;
        $Sms{Subject} =~ s/<OTRS_RESPONSIBLE_$_>/$ResponsiblePreferences{$_}/gi;
    }

    # cleanup
    $Sms{Subject} =~ s/<OTRS_RESPONSIBLE_.+?>/-/gi;
    $Sms{Body}    =~ s/<OTRS_RESPONSIBLE_.+?>/-/gi;

    # get ref of email params
    my %GetParam = %{ $Param{CustomerMessageParams} };
    for ( sort keys %GetParam ) {
        next if !$GetParam{$_};
        $Sms{Body}    =~ s/<OTRS_CUSTOMER_DATA_$_>/$GetParam{$_}/gi;
        $Sms{Subject} =~ s/<OTRS_CUSTOMER_DATA_$_>/$GetParam{$_}/gi;
    }

    # get customer data and replace it with <OTRS_CUSTOMER_DATA_...
    if ( $Article{CustomerUserID} ) {
        my %CustomerUser = $Self->{CustomerUserObject}->CustomerUserDataGet(
            User => $Article{CustomerUserID},
        );

        # replace customer stuff with tags
        for ( sort keys %CustomerUser ) {
            next if !$CustomerUser{$_};
            $Sms{Body}    =~ s/<OTRS_CUSTOMER_DATA_$_>/$CustomerUser{$_}/gi;
            $Sms{Subject} =~ s/<OTRS_CUSTOMER_DATA_$_>/$CustomerUser{$_}/gi;
        }
    }

    # cleanup all not needed <OTRS_CUSTOMER_DATA_ tags
    $Sms{Body}    =~ s/<OTRS_CUSTOMER_DATA_.+?>/-/gi;
    $Sms{Subject} =~ s/<OTRS_CUSTOMER_DATA_.+?>/-/gi;

    # latest customer and agent article
    my @ArticleBoxAgent = $Self->{TicketObject}->ArticleGet(
        TicketID      => $Param{TicketID},
        UserID        => $Param{UserID},
        DynamicFields => 0,
    );
    my %ArticleAgent;
    for my $Article ( reverse @ArticleBoxAgent ) {
        next if $Article->{SenderType} ne 'agent';
        %ArticleAgent = %{$Article};
        last;
    }

    my %ArticleContent = (
        'OTRS_CUSTOMER_' => \%Article,
        'OTRS_AGENT_'    => \%ArticleAgent,
    );

    for my $ArticleItem ( sort keys %ArticleContent ) {
        my %Article = %{ $ArticleContent{$ArticleItem} };

        if (%Article) {

            if ( $Article{Body} ) {

                # Use the same line length as HTMLUtils::toAscii to avoid
                #   line length problems.
                $Article{Body} =~ s/(^>.+|.{4,78})(?:\s|\z)/$1\n/gm;
            }

            for ( sort keys %Article ) {

                next if !$Article{$_};

                $Sms{Body}    =~ s/<$ArticleItem$_>/$Article{$_}/gi;
                $Sms{Subject} =~ s/<$ArticleItem$_>/$Article{$_}/gi;
            }

            # get accounted time
            my $AccountedTime = $Self->{TicketObject}->ArticleAccountedTimeGet(
                ArticleID => $Article{ArticleID},
            );

            my $MatchString = $ArticleItem . 'TimeUnit';
            $Sms{Body}    =~ s/<$MatchString>/$AccountedTime/gi;
            $Sms{Subject} =~ s/<$MatchString>/$AccountedTime/gi;

            # prepare subject (insert old subject)
            $Article{Subject} = $Self->{TicketObject}->TicketSubjectClean(
                TicketNumber => $Article{TicketNumber},
                Subject => $Article{Subject} || '',
            );

            for my $Type (qw(Subject Body)) {
                if ( $Sms{$Type} =~ /<$ArticleItem(SUBJECT)\[(.+?)\]>/ ) {
                    my $SubjectChar = $2;
                    my $Subject     = $Article{Subject};
                    $Subject =~ s/^(.{$SubjectChar}).*$/$1 [...]/;
                    $Sms{$Type} =~ s/<$ArticleItem(SUBJECT)\[.+?\]>/$Subject/g;
                }
            }

            $Sms{Subject} = $Self->{TicketObject}->TicketSubjectBuild(
                TicketNumber => $Article{TicketNumber},
                Subject      => $Sms{Subject} || '',
                Type         => 'New',
            );

            # prepare body (insert old email)
            if ( $Sms{Body} =~ /<$ArticleItem(EMAIL|NOTE|BODY)\[(.+?)\]>/g ) {
                my $Line       = $2;
                my @Body       = split( /\n/, $Article{Body} );
                my $NewOldBody = '';
                for ( my $i = 0; $i < $Line; $i++ ) {

                    # 2002-06-14 patch of Pablo Ruiz Garcia
                    # http://lists.otrs.org/pipermail/dev/2002-June/000012.html
                    if ( $#Body >= $i ) {
                        $NewOldBody .= "> $Body[$i]\n";
                    }
                }
                chomp $NewOldBody;
                $Sms{Body} =~ s/<$ArticleItem(EMAIL|NOTE|BODY)\[.+?\]>/$NewOldBody/g;
            }
        }

        # cleanup all not needed <OTRS_CUSTOMER_ and <OTRS_AGENT_ tags
        $Sms{Body}    =~ s/<$ArticleItem.+?>/-/gi;
        $Sms{Subject} =~ s/<$ArticleItem.+?>/-/gi;
    }

    # send sms
    if ( $Recipient{Type} eq 'Agent' ) {
        my %Address;

        # send sms
#        my $From = $Self->{ConfigObject}->Get('SmsSenderName') . ' <'
#            . $Self->{ConfigObject}->Get('SmsSenderEmail') . '>';
        # set "From" address from Article if exist, otherwise use ticket information, see bug# 9035
        if ( IsHashRefWithData( \%Article ) ) {
            %Address = $Self->{QueueObject}->GetSystemAddress( QueueID => $Article{QueueID} );
        }
        else {
            %Address = $Self->{QueueObject}->GetSystemAddress( QueueID => $Ticket{QueueID} );
        }

        my $ArticleType = $Recipient{SmsArticleType} || 'sms';

        # Send the SMS ##############################################################
        # COMPLEMENTO - Load list of Gateway Modules
        my %Gws;
        if ( ref $Self->{ConfigObject}->Get('SmsEvent::Gateway') eq 'HASH' ) {
            %Gws = %{ $Self->{ConfigObject}->Get('SmsEvent::Gateway') };
        } else {
            $Self->{LogObject}->Log(
                 Priority => 'notice',
                 Message  => "Can't get SMS Gateways information",
            );
        }
        
        $Self->{MainObject}->Require($Gws{$Sms{Data}->{Gateway}->[0]}->{Module});
        
        my $SmsEventObject = Kernel::System::SmsEvent->new( %{$Self} );
        
        return if !$SmsEventObject->SendSms(
            Gateway   => $Gws{$Sms{Data}->{Gateway}->[0]},
            Sms       => \%Sms,
            Recipient => \%Recipient,
        );
        #############################################################################

        # LOG and create article if sent successfuly
        my $ArticleID = $Self->{TicketObject}->ArticleCreate(
            ArticleType    => $ArticleType,
            SenderType     => 'system',
            TicketID       => $Param{TicketID},
            HistoryType    => 'SendCustomerSms',
            HistoryComment => "\%\%$Recipient{Email}",
            From           => "$Address{RealName} <$Address{Email}>",
            To             => $Recipient{Email},
            Subject        => $Sms{Subject},
            Body           => $Sms{Body},
            MimeType       => 'text/plain',
            Type           => 'text/plain',
            Charset        => $Sms{Charset},
            UserID         => $Param{UserID},
            Loop           => 1,
            Attachment     => $Param{Attachments},
        );


        # write history
        $Self->{TicketObject}->HistoryAdd(
            TicketID     => $Param{TicketID},
            HistoryType  => 'SendAgentSms',
            Name         => "\%\%$Sms{Name}\%\%$Recipient{Email}",
            CreateUserID => $Param{UserID},
        );

        # log event
        $Self->{LogObject}->Log(
            Priority => 'notice',
            Message  => "Sent agent '$Sms{Name}' sms to '$Recipient{Email}'.",
        );

        # ticket event
        $Self->{TicketObject}->EventHandler(
            Event => 'ArticleAgentNotification',
            Data  => {
                TicketID => $Param{TicketID},
            },
            UserID => $Param{UserID},
        );
    }
    else {
        my %Address;

        # set "From" address from Article if exist, otherwise use ticket information, see bug# 9035
        if ( IsHashRefWithData( \%Article ) ) {
            %Address = $Self->{QueueObject}->GetSystemAddress( QueueID => $Article{QueueID} );
        }
        else {
            %Address = $Self->{QueueObject}->GetSystemAddress( QueueID => $Ticket{QueueID} );
        }


        my $ArticleType = $Recipient{SmsArticleType} || 'sms';
        
        # Send the SMS ##############################################################
        # COMPLEMENTO - Load list of Gateway Modules
        my %Gws;
        if ( ref $Self->{ConfigObject}->Get('SmsEvent::Gateway') eq 'HASH' ) {
            %Gws = %{ $Self->{ConfigObject}->Get('SmsEvent::Gateway') };
        } else {
            $Self->{LogObject}->Log(
                 Priority => 'notice',
                 Message  => "Can't get SMS Gateways information",
            );
        }
        
        $Self->{MainObject}->Require($Gws{$Sms{Data}->{Gateway}->[0]}->{Module});
        
        my $SmsEventObject = Kernel::System::SmsEvent->new( %{$Self} );
        
        return if !$SmsEventObject->SendSms(
            Gateway   => $Gws{$Sms{Data}->{Gateway}->[0]},
            Sms       => \%Sms,
            Recipient => \%Recipient,
        );
        #############################################################################

        
        my $ArticleID = $Self->{TicketObject}->ArticleCreate(
            ArticleType    => $ArticleType,
            SenderType     => 'system',
            TicketID       => $Param{TicketID},
            HistoryType    => 'SendCustomerSms',
            HistoryComment => "\%\%$Recipient{Email}",
            From           => "$Address{RealName} <$Address{Email}>",
            To             => $Recipient{Email},
            Subject        => $Sms{Subject},
            Body           => $Sms{Body},
            MimeType       => 'text/plain',
            Type           => 'text/plain',
            Charset        => $Sms{Charset},
            UserID         => $Param{UserID},
            Loop           => 1,
            Attachment     => $Param{Attachments},
        );

        # log event
        $Self->{LogObject}->Log(
            Priority => 'notice',
            Message  => "Sent customer '$Sms{Name}' sms to '$Recipient{Email}'.",
        );

        # ticket event
        $Self->{TicketObject}->EventHandler(
            Event => 'ArticleCustomerNotification',
            Data  => {
                TicketID  => $Param{TicketID},
                ArticleID => $Param{ArticleID},
            },
            UserID => $Param{UserID},
        );
    }

    return 1;
}

1;
